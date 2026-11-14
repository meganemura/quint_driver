# rbs_inline: enabled

module QuintDriver
  # One module of a compiled Quint spec, and the rules a step action offers.
  class Spec
    # A move the step action can take: +action+ called with +args+ (IR nodes),
    # whose free names are the nondet picks drawn from +domains+ (name => IR
    # node of a set), in order, since a later set may read an earlier pick.
    # +fixed+ names the domains that are the same set in every state and
    # after every earlier pick, so a caller can evaluate each of them once.
    Rule = Struct.new(
      :action, #: String
      :args, #: Array[ir]
      :domains, #: Hash[String, ir]
      :fixed #: Set[String]
    )

    # @rbs @effects: Hash[String, ir]
    # @rbs @types: Hash[String, ir]
    # @rbs @main: String
    # @rbs @kinds: Hash[String, String]
    # @rbs @owners: Hash[Integer, String]
    # @rbs @observable: Array[String]

    attr_reader :declarations #: Array[ir]

    # The q:: definitions are what quint adds for --main, so only the module
    # a file compiled for first would have them. A module that imports reads
    # quint's flattened copy, where what it imports is its own. Without
    # +main+ the module is the one named after the file, as Quint.simulate
    # reads it, so the two agree when both leave it out.
    #
    # @rbs path: String
    # @rbs main: String
    # @rbs return: void
    def initialize(path, main: File.basename(path.to_s, ".qnt"))
      ir = Quint.compile(path, main:)
      declarations = ir.fetch("modules").find { _1["name"] == main }.fetch("declarations")
      ir = Quint.compile(path, main:, flat: true) if declarations.any? { %w[import instance export].include?(_1["kind"]) }
      @declarations = ir.fetch("modules").find { _1["name"] == main }.fetch("declarations")
                        .reject { _1["name"].to_s.start_with?("q::") }
      @effects = ir.fetch("effects")
      @types = ir.fetch("types")
      @main = main
    end

    # With +step+ nil, the model holds no rules: it evaluates definitions on
    # a state it is given, and takes no step.
    #
    # @rbs step: String?
    # @rbs return: Model
    def model(step = "step") = Model.send(:new, declarations, step ? rules(step) : [], owners)

    # Raises ArgumentError unless each of +names+ is a definition the model
    # can read in a state: a val or a def without parameters, not an action,
    # and not a sum type's case, which quint declares as a val too.
    #
    # @rbs names: Array[String]
    # @rbs return: void
    def observable!(names)
      name = names.find { !observable.include?(_1) } or return
      Agreement.refuse "quint: observe names #{name}, which is no definition without parameters of #{@main}; it has #{observable.sort.join(', ')}"
    end

    # Raises ArgumentError unless each of +names+ is a predicate, a boolean
    # val or def without parameters, as +argument+, such as invariants,
    # takes one. A name of another kind would read as an expectation that
    # never holds, or that the model cannot evaluate.
    #
    # @rbs names: Array[String]
    # @rbs argument: String
    # @rbs return: void
    def predicates!(names, argument)
      @kinds ||= declarations.select { _1["name"] }.to_h { [ _1["name"], Quint.send(:kind_of, _1, @types) ] }
      name = names.find { @kinds[_1] != "a predicate" } or return
      what = @kinds.key?(name) ? "#{@kinds[name]} of #{@main}" : "which #{@main} neither declares nor imports"
      Quint.send(:misnamed, argument, name, what, "a predicate", @kinds)
    end

    # The names invariants: and violate: take: every boolean val or def
    # without parameters, in the order the module declares them, so a hunt
    # that reads this list runs a val added later too.
    #
    # @rbs return: Array[String]
    def expectations
      predicates!([], "invariants")
      declarations.sort_by { _1["id"] }.filter_map { _1["name"] if @kinds[_1["name"]] == "a predicate" }.uniq
    end

    # The definition that writes each IR node, by node id, so the model names
    # where a node is written when it cannot evaluate it.
    #
    # @rbs return: Hash[Integer, String]
    def owners
      none = {} #: Hash[Integer, String]
      @owners ||= declarations.each_with_object(none) do |declaration, owners|
        ids_in(declaration["expr"]).each { owners[_1] = declaration["name"] } if declaration["kind"] == "def"
      end.freeze
    end

    # Walks +step+: `any` splits into rules, `nondet x = S.oneOf()` adds a
    # domain, and a call of a declared action ends a rule. A parameterless
    # action made of `any` (such as `step` inside a wider step) opens in place.
    # An `all` of one action is that action, as in `all { nondet x = ...
    # any { ... } }`; an `all` of more holds a condition no rule can carry.
    #
    # @rbs step: String
    # @rbs return: Array[Rule]
    def rules(step)
      actions = declarations.select { _1["qualifier"] == "action" }.to_h { [ _1["name"], _1 ] }
      Agreement.refuse(Quint.send(:without_init, @main)) unless actions.key?("init")
      choice = ->(node) { node["kind"] == "app" && node["opcode"] == "actionAny" }
      walk = lambda do |node, domains, within|
        if choice.(node)
          node["args"].flat_map { walk.(_1, domains, within) }
        elsif node["kind"] == "app" && node["opcode"] == "actionAll" && node["args"].size == 1
          walk.(node["args"].first, domains, within)
        elsif node["kind"] == "let" && node["opdef"]["qualifier"] == "nondet" && node["opdef"]["expr"]["opcode"] == "oneOf"
          domain = node["opdef"]["expr"]["args"].first #: ir
          walk.(node["expr"], domains.merge({ node["opdef"]["name"] => domain }), within)
        elsif actions.key?(node["name"])
          body = actions[node["name"]]["expr"]
          choice.(body) ? walk.(body, domains, node["name"]) : [ Rule.new(node["name"], [], domains, fixed(domains)) ]
        elsif node["kind"] == "app" && actions.key?(node["opcode"])
          [ Rule.new(node["opcode"], node["args"], domains, fixed(domains)) ]
        else
          arm = node["opcode"] == "assign" ? "assigns #{node['args'][0]['name']}'" : "holds #{node['opcode'] || node['kind']}"
          raise Unsupported, "quint: #{within} #{arm} in an arm that names no action; name every action in #{step}"
        end
      end
      top = actions.fetch(step) { Agreement.refuse "quint: no action is named #{step}; the module has #{actions.keys.sort.join(', ')}" }
      walk.(top["expr"], {}, step)
    end

    private
      # @rbs return: Array[String]
      def observable
        @observable ||= declarations.select do
          %w[val def pureval puredef].include?(_1["qualifier"]) && _1["expr"]["kind"] != "lambda" && _1["expr"]["opcode"] != "variant"
        end.map { _1["name"] }
      end

      # The effect quint gives an expression that reads no variable.
      READS_NONE = {
        "kind" => "concrete",
        "components" => [] #: Array[json]
      }.freeze #: Hash[String, json]
      private_constant :READS_NONE

      # Quint's effect of a set says which variables it reads, and a pick is
      # not a variable, so a set also has to name no earlier pick. A lambda
      # parameter that shadows a pick counts as the pick: one evaluation too
      # many is only slower.
      #
      # @rbs domains: Hash[String, ir]
      # @rbs return: Set[String]
      def fixed(domains)
        domains.each_with_index.filter_map do |(name, domain), index|
          reads_none = @effects.dig(domain["id"].to_s, "effect") == READS_NONE
          name if reads_none && !names_in(domain).intersect?(domains.keys.take(index))
        end.to_set
      end

      # @rbs node: json
      # @rbs return: Array[Integer]
      def ids_in(node)
        case node
        when Hash
          id = node["id"] #: Integer?
          [ id, *node.each_value.flat_map { ids_in(_1) } ].compact
        when Array then node.flat_map { ids_in(_1) }
        else []
        end
      end

      # @rbs node: json
      # @rbs return: Array[String]
      def names_in(node)
        case node
        when Hash
          name = node["kind"] == "name" ? node["name"] : node["opcode"] #: String?
          [ name, *node.each_value.flat_map { names_in(_1) } ].compact
        when Array then node.flat_map { names_in(_1) }
        else []
        end
      end
  end
end
