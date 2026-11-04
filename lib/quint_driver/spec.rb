module QuintDriver
  # One module of a compiled Quint spec, and the rules a step action offers.
  class Spec
    # A move the step action can take: +action+ called with +args+ (IR nodes),
    # whose free names are the nondet picks drawn from +domains+ (name => IR
    # node of a set), in order, since a later set may read an earlier pick.
    # +fixed+ names the domains that are the same set in every state and
    # after every earlier pick, so a caller can evaluate each of them once.
    Rule = Struct.new(:action, :args, :domains, :fixed)

    attr_reader :declarations

    # The q:: definitions are what quint adds for --main, so only the module
    # a file compiled for first would have them. A module that imports reads
    # quint's flattened copy, where what it imports is its own.
    def initialize(path, main:)
      ir = Quint.compile(path, main:)
      declarations = ir.fetch("modules").find { _1["name"] == main }.fetch("declarations")
      ir = Quint.compile(path, main:, flat: true) if declarations.any? { %w[import instance export].include?(_1["kind"]) }
      @declarations = ir.fetch("modules").find { _1["name"] == main }.fetch("declarations")
                        .reject { _1["name"].to_s.start_with?("q::") }
      @effects = ir.fetch("effects")
    end

    def model(step = "step") = Model.send(:new, declarations, rules(step), owners)

    # The definition that writes each IR node, by node id, so the model names
    # where a node is written when it cannot evaluate it.
    def owners
      @owners ||= declarations.each_with_object({}) do |declaration, owners|
        ids_in(declaration["expr"]).each { owners[_1] = declaration["name"] } if declaration["kind"] == "def"
      end.freeze
    end

    # Walks +step+: `any` splits into rules, `nondet x = S.oneOf()` adds a
    # domain, and a call of a declared action ends a rule. A parameterless
    # action made of `any` (such as `step` inside a wider step) opens in place.
    # An `all` of one action is that action, as in `all { nondet x = ...
    # any { ... } }`; an `all` of more holds a condition no rule can carry.
    def rules(step)
      actions = declarations.select { _1["qualifier"] == "action" }.to_h { [ _1["name"], _1 ] }
      choice = ->(node) { node["kind"] == "app" && node["opcode"] == "actionAny" }
      walk = lambda do |node, domains, within|
        if choice.(node)
          node["args"].flat_map { walk.(_1, domains, within) }
        elsif node["kind"] == "app" && node["opcode"] == "actionAll" && node["args"].size == 1
          walk.(node["args"].first, domains, within)
        elsif node["kind"] == "let" && node["opdef"]["qualifier"] == "nondet" && node["opdef"]["expr"]["opcode"] == "oneOf"
          walk.(node["expr"], domains.merge(node["opdef"]["name"] => node["opdef"]["expr"]["args"].first), within)
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
      top = actions.fetch(step) { raise ArgumentError, "quint: no action is named #{step}; the module has #{actions.keys.sort.join(', ')}" }
      walk.(top["expr"], {}, step)
    end

    private
      # Quint's effect of a set says which variables it reads, and a pick is
      # not a variable, so a set also has to name no earlier pick. A lambda
      # parameter that shadows a pick counts as the pick: one evaluation too
      # many is only slower.
      def fixed(domains)
        domains.each_with_index.filter_map do |(name, domain), index|
          reads_none = @effects.dig(domain["id"].to_s, "effect") == { "kind" => "concrete", "components" => [] }
          name if reads_none && !names_in(domain).intersect?(domains.keys.take(index))
        end.to_set
      end

      def ids_in(node)
        case node
        when Hash then [ node["id"], *node.each_value.flat_map { ids_in(_1) } ].compact
        when Array then node.flat_map { ids_in(_1) }
        else []
        end
      end

def names_in(node)
        case node
        when Hash then [ node["kind"] == "name" ? node["name"] : node["opcode"], *node.each_value.flat_map { names_in(_1) } ].compact
        when Array then node.flat_map { names_in(_1) }
        else []
        end
      end
  end
end
