module QuintDriver
  # One module of a compiled Quint spec, and the rules a step action offers.
  class Spec
    # A move the step action can take: +action+ called with +args+ (IR nodes),
    # whose free names are the nondet picks drawn from +domains+ (name => IR
    # node of a set), in order, since a later set may read an earlier pick.
    Rule = Struct.new(:action, :args, :domains)

    attr_reader :declarations

    def initialize(path, main:)
      @declarations = Quint.compile(path, main:).fetch("modules").find { _1["name"] == main }.fetch("declarations")
    end

    def model(step = "step") = Model.send(:new, declarations, rules(step))

    # Walks +step+: `any` splits into rules, `nondet x = S.oneOf()` adds a
    # domain, and a call of a declared action ends a rule. A parameterless
    # action made of `any` (such as `step` inside a wider step) opens in place.
    def rules(step)
      actions = declarations.select { _1["qualifier"] == "action" }.to_h { [ _1["name"], _1 ] }
      choice = ->(node) { node["kind"] == "app" && node["opcode"] == "actionAny" }
      walk = lambda do |node, domains|
        if choice.(node)
          node["args"].flat_map { walk.(_1, domains) }
        elsif node["kind"] == "let" && node["opdef"]["qualifier"] == "nondet" && node["opdef"]["expr"]["opcode"] == "oneOf"
          walk.(node["expr"], domains.merge(node["opdef"]["name"] => node["opdef"]["expr"]["args"].first))
        elsif actions.key?(node["name"])
          body = actions[node["name"]]["expr"]
          choice.(body) ? walk.(body, domains) : [ Rule.new(node["name"], [], domains) ]
        elsif node["kind"] == "app" && actions.key?(node["opcode"])
          [ Rule.new(node["opcode"], node["args"], domains) ]
        else
          raise Unsupported, "quint: #{step} holds a #{node['kind']} #{node['opcode']} that names no action; name every action in step"
        end
      end
      walk.(actions.fetch(step)["expr"], {})
    end
  end
end
