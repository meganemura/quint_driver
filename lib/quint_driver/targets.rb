# rbs_inline: enabled

require "prism"

module QuintDriver
  # The places in a Ruby app where a hunt pays: code where two writes must
  # agree and something can fail between them. It reads the source only, so
  # it names lines to read, never bugs: each hit is a pattern the bugs a hunt
  # finds have had, such as a rescue inside a transaction or a save whose
  # answer nobody reads. Files are ranked by how many kinds of hit they hold,
  # since the bugs sat where several kinds meet.
  #
  # Prism, which ships with Ruby, reads each file, so comments, strings,
  # heredocs and regexps are not matched, and the method a line sits in is
  # the def that holds it, not the def above it.
  module Targets
    # @rbs!
    #   # A file's lines as written, its lines with comments and strings
    #   # blanked, and its defs.
    #   type source = [Array[String], Array[String], Array[Def]]

    Hit = Data.define(
      :kind, #: String
      :file, #: String
      :line, #: Integer
      :code #: String
    )

    SAVE = /\A\s*([@\w:.]+\.)?(save|update|create|destroy|update_attribute)([( ].*)?\z/ #: Regexp
    # A save whose answer the line itself reads, as in `save or raise`.
    READ = /\s(or|and)\s|\|\||&&/ #: Regexp
    WRITE = /\.(save|update|create|destroy|update_attribute|update_columns?|increment|decrement)!?(\(|\s|\z)|\A\s*(save|update)!?(\(|\s|\z)/ #: Regexp
    LOCK = /\block\b|\bwith_lock\b|\block!/ #: Regexp
    KINDS = {
      "transaction" => /\btransaction\b|\bwith_lock\b|\block!/,
      "rescue" => /\A\s*rescue\b/,
      "unchecked-save" => SAVE,
      "answers-false" => /\A\s*false\s*\z|\breturn false\b/,
      "skips-callbacks" => /\b(update_all|update_columns?|delete_all|insert_all|upsert_all|update_counters|increment_counter|decrement_counter)\b/,
      "counter-write" => /\b(increment|decrement)!?\(\s*:\w+|\w+_count\s*[+-]=/,
      "retry" => /\b(retry_on|discard_on)\b|\A\s*retry\b/,
      # An outside call, or an error class of the app's own, which is how a
      # service that calls out says it can fail.
      "outside" => %r{Net::HTTP|Faraday|HTTParty|RestClient|\bClient\b|Api\b|_api\b|\.(post|get|put|patch|delete)\(\s*["'/]|broadcast|
                      \A\s*class\s+[\w:]+\s*<\s*([\w:]*Error|StandardError|RuntimeError)\b}x
    }.freeze #: Hash[String, Regexp]
    # A method with one of these names is called on many receivers that are
    # not its own, so a call counts only where it names the method's class.
    COMMON = %w[call perform run process execute save update create destroy].freeze #: Array[String]

    # A def, with the lines of the checks in it that read stored state.
    Def = Data.define(
      :name, #: String
      :owner, #: String?
      :first, #: Integer
      :last, #: Integer
      :checks #: Array[Integer]
    )

    # Every hit under +root+'s app/ and lib/, the spec and test folders left
    # out, comments and strings skipped, each write after a check in a
    # method that takes no lock, as the kind "check-then-write", and each
    # call that drops the answer of a method that can fail without raising,
    # as the kind "dropped-result".
    #
    # @rbs root: String
    # @rbs return: Array[Hit]
    def self.scan(root)
      files = Dir.glob(%w[app/**/*.rb lib/**/*.rb], base: root)
                 .reject { _1.match?(%r{(\A|/)(spec|test)/}) }.select { File.file?(File.join(root, _1)) }.sort
      sources = files.to_h { [ _1, read(File.join(root, _1)) ] }
      hits = sources.flat_map do |file, (lines, code, _)|
        code.each_with_index.flat_map do |text, index|
          KINDS.filter_map do |kind, pattern|
            next if kind == "unchecked-save" && text.match?(READ)

            Hit.new(kind, file, index + 1, lines[index].strip) if text.match?(pattern)
          end
        end
      end
      hits + checked(sources) + dropped(hits, sources)
    end

    # The files ranked, each with its hits, as the `quint_driver targets`
    # command prints them.
    #
    # @rbs root: String
    # @rbs top: Integer
    # @rbs return: String
    def self.report(root, top: 10)
      raise ArgumentError, "quint: top takes 1 or more, not #{top}" if top < 1

      by_file = scan(root).group_by(&:file).sort_by { |file, hits| [ -hits.map(&:kind).uniq.size, -hits.size, file ] }
      return none(root) if by_file.empty?

      by_file.first(top).map do |file, hits|
        kinds = hits.map(&:kind).uniq
        [ "#{file}: #{kinds.join(', ')}", *hits.sort_by(&:line).map { "  #{_1.line}  #{_1.kind}  #{_1.code}" } ].join("\n")
      end.join("\n\n") + "\n#{"\n#{by_file.size - top} more #{by_file.size - top == 1 ? 'file' : 'files'} with fewer kinds; pass --top N to see them.\n" if by_file.size > top}"
    end

    # The lines of a file as written, the same lines with every comment,
    # string, heredoc and regexp body blanked, and the defs it holds.
    #
    # @rbs path: String
    # @rbs return: source
    def self.read(path)
      source = File.read(path, encoding: "UTF-8").scrub
      code = source.b
      Prism.lex(source).value.each do |token, _|
        next unless %i[COMMENT EMBDOC_BEGIN EMBDOC_LINE EMBDOC_END STRING_CONTENT HEREDOC_END __END__].include?(token.type)

        range = token.location.start_offset...token.location.end_offset
        blanked = code[range] #: String
        code[range] = blanked.gsub(/[^\n]/n, " ")
      end
      [ source.lines(chomp: true), code.force_encoding("UTF-8").scrub.lines(chomp: true), defs(Prism.parse(source).value) ]
    end

    # @rbs node: Prism::Node
    # @rbs owner: String?
    # @rbs return: Array[Def]
    def self.defs(node, owner = nil)
      case node
      when Prism::ClassNode, Prism::ModuleNode
        name = node.constant_path.slice.split("::").last
        node.compact_child_nodes.flat_map { defs(_1, name) }
      when Prism::DefNode
        writes = within(node).grep(Prism::LocalVariableWriteNode) #: Array[Prism::LocalVariableWriteNode]
        loaded = 2.times.reduce([]) { |known, _| writes.select { stored?(_1.value, known) }.map(&:name) }
        checks = within(node).filter_map { _1.predicate if _1.is_a?(Prism::IfNode) || _1.is_a?(Prism::UnlessNode) }
                             .select { stored?(_1, loaded) }.map { _1.location.start_line }
        [ Def.new(node.name.to_s, owner, node.location.start_line, node.location.end_line, checks),
          *node.compact_child_nodes.flat_map { defs(_1, owner) } ]
      else node.compact_child_nodes.flat_map { defs(_1, owner) }
      end
    end

    # Every node of a def, its nested defs left out.
    #
    # @rbs node: Prism::Node
    # @rbs return: Array[Prism::Node]
    def self.within(node)
      node.compact_child_nodes.flat_map { _1.is_a?(Prism::DefNode) ? [] : [ _1, *within(_1) ] }
    end

    # Whether a condition reads what the app stored, not only the method's
    # arguments: an attribute, an instance variable, a query on a class, or
    # a local the def loaded from one of those. A check of an argument alone
    # cannot go stale between the read and the write, so it is no sign of a
    # race.
    #
    # @rbs node: Prism::Node
    # @rbs loaded: Array[Symbol]
    # @rbs return: bool
    def self.stored?(node, loaded)
      case node
      when Prism::InstanceVariableReadNode, Prism::ConstantReadNode, Prism::ConstantPathNode then true
      when Prism::LocalVariableReadNode then loaded.include?(node.name)
      when Prism::CallNode
        node.receiver.nil? && node.variable_call? && !%i[params request].include?(node.name) ||
          node.compact_child_nodes.any? { stored?(_1, loaded) }
      else node.compact_child_nodes.any? { stored?(_1, loaded) }
      end
    end

    # The innermost def that holds +line+.
    #
    # @rbs defs: Array[Def]
    # @rbs line: Integer
    # @rbs return: Def?
    def self.around(defs, line) = defs.select { _1.first <= line && line <= _1.last }.min_by { _1.last - _1.first }

    # A write is a save, an update, a create or a destroy, or a call of a
    # method of the app that holds one, such as `parcel.assign_to!(...)`.
    #
    # @rbs sources: Hash[String, source]
    # @rbs return: Array[Hit]
    def self.checked(sources)
      writers = sources.values.flat_map do |_, code, defs|
        defs.select { |method| (method.first..method.last).any? { code[_1 - 1].to_s.match?(WRITE) } }.map(&:name)
      end.uniq - COMMON
      write = writers.empty? ? WRITE : Regexp.union(WRITE, /\.(#{writers.map { Regexp.escape(_1) }.join('|')})(\(|\s|\z)/)
      sources.flat_map do |file, (lines, code, defs)|
        defs.flat_map do |method|
          check = method.checks.min or next []
          body = (method.first - 1...method.last).map { [ _1 + 1, code[_1].to_s ] } #: Array[[Integer, String]]
          next [] if body.any? { |_, text| text.match?(LOCK) }

          body.select { |line, _| line > check }
              .filter_map { |line, text| Hit.new("check-then-write", file, line, lines[line - 1].strip) if text.match?(write) }
        end
      end
    end

    # @rbs hits: Array[Hit]
    # @rbs sources: Hash[String, source]
    # @rbs return: Array[Hit]
    def self.dropped(hits, sources)
      methods = hits.select { %w[unchecked-save answers-false].include?(_1.kind) }.filter_map { around(sources[_1.file][2], _1.line) }.uniq
      return [] if methods.empty?

      sources.flat_map do |file, (lines, code, defs)|
        code.each_with_index.filter_map do |text, index|
          next if text.match?(/\A\s*def /)

          called = methods.find do |method|
            text.match?(/\A\s*([@\w:.()]+\.)?#{Regexp.escape(method.name)}(\(.*\))?\s*\z/) &&
              (!COMMON.include?(method.name) || (method.owner && text.match?(/\b#{Regexp.escape(method.owner)}\b/)))
          end
          Hit.new("dropped-result", file, index + 1, lines[index].strip) if called
        end
      end
    end

    # @rbs root: String
    # @rbs return: String
    def self.none(root)
      <<~TEXT
        No hit under #{root}/app or #{root}/lib.
        That says no line matched, not that a hunt cannot pay here. List the entry points (controllers, jobs, rake tasks), ask which of them write the same rows, and read where one of them calls a service that can fail.
      TEXT
    end
    private_class_method :read, :defs, :within, :stored?, :around, :checked, :dropped, :none
  end
end
