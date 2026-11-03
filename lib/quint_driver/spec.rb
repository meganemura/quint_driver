module QuintDriver
  # One module of a compiled Quint spec, and the rules a step action offers.
  class Spec
    # A move the step action can take: +action+ called with +args+ (IR nodes),
    # whose free names are the nondet picks drawn from +domains+ (name => IR
    # node of a set), in order, since a later set may read an earlier pick.
    # +within+ names the action whose body calls +action+.
    Rule = Struct.new(:action, :args, :domains, :within)

    attr_reader :declarations

    # The q:: definitions are what quint adds for --main, so only the module
    # a file compiled for first would have them.
    def initialize(path, main:)
      @declarations = Quint.compile(path, main:).fetch("modules").find { _1["name"] == main }.fetch("declarations")
                           .reject { _1["name"].to_s.start_with?("q::") }
    end

    def model(step = "step") = Model.send(:new, declarations, rules(step))

    # Walks +step+: `any` splits into rules, `nondet x = S.oneOf()` adds a
    # domain, and a call of a declared action ends a rule. A parameterless
    # action made of `any` (such as `step` inside a wider step) opens in place.
    def rules(step)
      actions = declarations.select { _1["qualifier"] == "action" }.to_h { [ _1["name"], _1 ] }
      choice = ->(node) { node["kind"] == "app" && node["opcode"] == "actionAny" }
      walk = lambda do |node, domains, within|
        if choice.(node)
          node["args"].flat_map { walk.(_1, domains, within) }
        elsif node["kind"] == "let" && node["opdef"]["qualifier"] == "nondet" && node["opdef"]["expr"]["opcode"] == "oneOf"
          walk.(node["expr"], domains.merge(node["opdef"]["name"] => node["opdef"]["expr"]["args"].first), within)
        elsif actions.key?(node["name"])
          body = actions[node["name"]]["expr"]
          choice.(body) ? walk.(body, domains, node["name"]) : [ Rule.new(node["name"], [], domains, within) ]
        elsif node["kind"] == "app" && actions.key?(node["opcode"])
          [ Rule.new(node["opcode"], node["args"], domains, within) ]
        else
          arm = node["opcode"] == "assign" ? "assigns #{node['args'][0]['name']}'" : "holds #{node['opcode'] || node['kind']}"
          raise Unsupported, "quint: #{within} #{arm} in an arm that names no action; name every action in #{step}"
        end
      end
      walk.(actions.fetch(step)["expr"], {}, step)
    end
  end
end
