module QuintDriver
  # Evaluates a spec's JSON IR inside the Ruby process, so a Hegel step costs
  # no call to another process. It covers the operators a command-per-action
  # spec uses and raises Unsupported on any other, so a spec that outgrows it
  # fails loudly instead of being judged wrongly. It answers the driver
  # protocol too, which is how it is held to Quint: replay Quint's own traces
  # through it.
  class Model
    Variant = Struct.new(:tag, :value)

    class Unsupported < StandardError; end

    Closure = Struct.new(:params, :body, :env)

    def initialize(declarations, rules)
      @defs = declarations.select { _1["kind"] == "def" }.to_h { [ _1["name"], _1 ] }
      @vars = declarations.select { _1["kind"] == "var" }.map { _1["name"] }
      @rules = rules.to_h { [ _1.action, _1 ] }
      @state = {}
    end

    # The driver protocol. Picks from a trace are plain values, which equal
    # the model's own for strings, numbers, and booleans; a variant pick would
    # need its type to be rebuilt.
    def step(action, picks)
      args = action == "init" ? [] : @rules.fetch(action).args.map { value(_1, picks) }
      enter(try(action, args) || raise(Mismatch, "quint: the model refused #{action} #{picks.inspect}"))
    end

    def state = Model.plain(@state)

    # The state the action would reach, or nil when it is disabled. The model
    # stays where it is, so a caller can ask which actions are enabled.
    def try(name, args = [])
      expr = @defs.fetch(name)["expr"]
      env = {}
      if expr["kind"] == "lambda"
        env = expr["params"].map { _1["name"] }.zip(args).to_h
        expr = expr["expr"]
      end
      @next = {}
      return nil unless eval(expr, env)

      missing = @vars - @next.keys
      raise Unsupported, "quint: #{name} leaves #{missing.join(', ')} unassigned" if missing.any?

      @next
    end

    def enter(state) = @state = state

    def value(node_or_name, env = {})
      node = node_or_name.is_a?(String) ? { "kind" => "name", "name" => node_or_name } : node_or_name
      eval(node, env)
    end

    def self.plain(value)
      case value
      when Variant then value.value == [] ? value.tag : [ value.tag, plain(value.value) ]
      when Set then value.to_set { plain(_1) }
      when Hash then value.to_h { |k, v| [ plain(k), plain(v) ] }
      when Array then value.map { plain(_1) }
      else value
      end
    end

    private
      def eval(node, env)
        case node["kind"]
        when "str", "int", "bool" then node["value"]
        when "name" then lookup(node["name"], env)
        when "lambda" then Closure.new(node["params"].map { _1["name"] }, node["expr"], env)
        when "let"
          definition = node["opdef"]
          eval(node["expr"], env.merge(definition["name"] => eval(definition["expr"], env)))
        when "app" then apply(node["opcode"], node["args"], env)
        else raise Unsupported, "quint: no evaluation for IR kind #{node['kind']}"
        end
      end

      def lookup(name, env)
        return env[name] if env.key?(name)
        return @state.fetch(name) if @vars.include?(name)

        definition = @defs.fetch(name) { raise Unsupported, "quint: unknown name #{name}" }
        eval(definition["expr"], {})
      end

      def call(closure, args)
        eval(closure.body, closure.env.merge(closure.params.zip(args).to_h))
      end

      def apply(op, args, env)
        v = ->(i) { eval(args[i], env) }
        case op
        when "actionAll", "and" then args.all? { eval(_1, env) }
        when "assign" then @next[args[0]["name"]] = v.(1); true
        when "or" then args.any? { eval(_1, env) }
        when "not" then !v.(0)
        when "implies" then !v.(0) || v.(1)
        when "eq", "iff" then v.(0) == v.(1)
        when "neq" then v.(0) != v.(1)
        when "ite" then v.(0) ? eval(args[1], env) : eval(args[2], env)
        when "igt" then v.(0) > v.(1)
        when "igte" then v.(0) >= v.(1)
        when "ilt" then v.(0) < v.(1)
        when "ilte" then v.(0) <= v.(1)
        when "iadd" then v.(0) + v.(1)
        when "isub" then v.(0) - v.(1)
        when "Set" then args.to_set { eval(_1, env) }
        when "contains" then v.(0).include?(v.(1))
        when "in" then v.(1).include?(v.(0))
        when "union" then v.(0) | v.(1)
        when "intersect" then v.(0) & v.(1)
        when "exclude" then v.(0) - v.(1)
        when "subseteq" then v.(0).subset?(v.(1))
        when "size" then v.(0).size
        when "exists" then (fn = v.(1); v.(0).any? { call(fn, [ _1 ]) })
        when "forall" then (fn = v.(1); v.(0).all? { call(fn, [ _1 ]) })
        when "filter" then (fn = v.(1); v.(0).select { call(fn, [ _1 ]) }.to_set)
        when "map" then (fn = v.(1); v.(0).to_set { call(fn, [ _1 ]) })
        when "Map" then args.to_h { eval(_1, env) }
        when "put", "with" then v.(0).merge(v.(1) => v.(2))
        when "get" then v.(0).fetch(v.(1)) { raise Unsupported, "quint: key #{v.(1).inspect} is not in the map" }
        when "keys" then v.(0).keys.to_set
        when "Tup" then args.map { eval(_1, env) }
        when "item" then v.(0).fetch(v.(1) - 1)
        when "Rec" then args.each_slice(2).to_h { |k, x| [ eval(k, env), eval(x, env) ] }
        when "field" then v.(0).fetch(v.(1))
        when "variant" then Variant.new(v.(0), v.(1))
        when "matchVariant"
          target = v.(0)
          arm = args.drop(1).each_slice(2).find { |label, _| [ target.tag, "_" ].include?(eval(label, env)) }
          call(eval(arm[1], env), [ target.value ])
        else
          definition = @defs.fetch(op) { raise Unsupported, "quint: no evaluation for operator #{op}" }
          # A definition is a lambda, or another operator's name (`def doubleOf = twice`).
          call(eval(definition["expr"], {}), args.map { eval(_1, env) })
        end
      end
  end
end
