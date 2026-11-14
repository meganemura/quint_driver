module QuintDriver
  # The places in a Ruby app where a hunt pays: code where two writes must
  # agree and something can fail between them. It reads the source only, so
  # it names lines to read, never bugs: each hit is a pattern the bugs a hunt
  # finds have had, such as a rescue inside a transaction or a save whose
  # answer nobody reads. Files are ranked by how many kinds of hit they hold,
  # since the bugs sat where several kinds meet.
  module Targets
    Hit = Data.define(:kind, :file, :line, :code)

    SAVE = /\A\s*([@\w:.]+\.)?(save|update|create|destroy|update_attribute)([( ].*)?\z/
    KINDS = {
      "transaction" => /\btransaction\b|\bwith_lock\b|\block!/,
      "rescue" => /\A\s*rescue\b/,
      "unchecked-save" => SAVE,
      "answers-false" => /\A\s*false\s*\z|\breturn false\b/,
      "skips-callbacks" => /\b(update_all|update_columns?|delete_all|insert_all|upsert_all|update_counters|increment_counter|decrement_counter)\b/,
      "counter-write" => /\b(increment|decrement)!?\(\s*:\w+|\w+_count\s*[+-]=/,
      "retry" => /\b(retry_on|discard_on)\b|\A\s*retry\b/,
      "outside" => %r{Net::HTTP|Faraday|HTTParty|RestClient|\bClient\b|Api\b|_api\b|\.(post|get|put|patch|delete)\(\s*["'/]|broadcast}
    }.freeze

    # Every hit under +root+'s app/ and lib/, the spec and test folders left
    # out, comments skipped, and each call that drops the answer of a method
    # that can fail without raising, as the kind "dropped-result".
    def self.scan(root)
      files = Dir.glob(%w[app/**/*.rb lib/**/*.rb], base: root).reject { _1.match?(%r{(\A|/)(spec|test)/}) }.sort
      # Ruby reads its source as UTF-8 whatever the locale says, and so does this.
      sources = files.to_h { [ _1, File.readlines(File.join(root, _1), chomp: true, encoding: "UTF-8").map(&:scrub) ] }
      hits = sources.flat_map do |file, lines|
        lines.each_with_index.flat_map do |code, index|
          next [] if code.lstrip.start_with?("#")

          KINDS.filter_map { |kind, pattern| Hit.new(kind, file, index + 1, code.strip) if code.match?(pattern) }
        end
      end
      hits + dropped(hits, sources)
    end

    # The files ranked, each with its hits, as the `quint_driver targets`
    # command prints them.
    def self.report(root, top: 10)
      by_file = scan(root).group_by(&:file).sort_by { |file, hits| [ -hits.map(&:kind).uniq.size, -hits.size, file ] }
      return "No hit under #{root}/app or #{root}/lib.\n" if by_file.empty?

      by_file.first(top).map do |file, hits|
        kinds = hits.map(&:kind).uniq
        [ "#{file}: #{kinds.join(', ')}", *hits.sort_by(&:line).map { "  #{_1.line}  #{_1.kind}  #{_1.code}" } ].join("\n")
      end.join("\n\n") + "\n#{"\n#{by_file.size - top} more files with fewer kinds; pass --top N to see them.\n" if by_file.size > top}"
    end

    def self.dropped(hits, sources)
      names = hits.select { %w[unchecked-save answers-false].include?(_1.kind) }.filter_map do |hit|
        sources[hit.file].first(hit.line).reverse.find { _1.match?(/\A\s*def /) }&.then { _1[/def (?:self\.)?(\w+[?!]?)/, 1] }
      end.uniq
      return [] if names.empty?

      call = /\A\s*([@\w:.]+\.)?(#{names.map { Regexp.escape(_1) }.join('|')})(\(.*\))?\s*\z/
      sources.flat_map do |file, lines|
        lines.each_with_index.filter_map do |code, index|
          Hit.new("dropped-result", file, index + 1, code.strip) if code.match?(call) && !code.match?(/\A\s*def /)
        end
      end
    end
    private_class_method :dropped
  end
end
