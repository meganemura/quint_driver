module QuintDriver
  # Evaluates a spec's JSON IR inside the Ruby process, so a Hegel step costs
  # no call to another process. It covers the operators a command-per-action
  # spec uses and raises Unsupported on any other, so a spec that outgrows it
  # fails loudly instead of being judged wrongly. It answers the driver
  # protocol too, which is how it is held to Quint: replay Quint's own traces
  # through it.
  class Model
    Variant = Struct.new(:tag, :value)

    Closure = Struct.new(:params, :body, :env)

    # Spec#model is the one way to build a model: the evaluator trusts the
    # shape of quint's compiled IR and checks none of it.
    private_class_method :new

    def initialize(declarations, rules)
      @defs = declarations.select { _1["kind"] == "def" }.to_h { [ _1["name"], _1 ] }
      @vars = declarations.select { _1["kind"] == "var" }.map { _1["name"] }
      @rules = rules.to_h { [ _1.action, _1 ] }
      @state = {}
      @constant = {}
    end

    # The driver protocol. Picks from a trace are plain values; each one
    # becomes the element of its domain that reads as the same plain value,
    # so a variant pick is a variant again.
    def step(action, picks)
      args = if action == "init" then []
             else
               # Quint names a move after step itself when step is one action,
               # or a nondet pick, that no `any` wraps.
               rule = @rules.fetch(action) do
                 raise Unsupported, "quint: no action of step is named #{action}; write step as any { ... } so each move names its action"
               end
               typed = rule.domains.each_with_object({}) do |(name, domain), chosen|
                 pick = picks.fetch(name) { raise Unsupported, "quint: #{action} needs a pick for #{name}, and the move gives none" }
                 chosen[name] = value(domain, chosen).find { Model.plain(_1) == pick } ||
                                raise(Mismatch, "quint: the model cannot pick #{name} = #{pick.inspect} for #{action}")
               end
               rule.args.map { value(_1, typed) }
             end
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

    # Every [action, picks, next state] that +rule+, a Spec::Rule, allows
    # now, in a fixed order, so the same draw means the same move from the
    # same state.
    def moves(rule)
      picks_of(rule.domains.to_a, {}).filter_map do |picks|
        after = try(rule.action, rule.args.map { value(_1, picks) })
        [ rule.action, picks, after ] if after
      end
    end

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
      def picks_of(domains, picks)
        return [ picks ] if domains.empty?

        (name, domain), *rest = domains
        value(domain, picks).to_a.sort_by(&:to_s).flat_map { picks_of(rest, picks.merge(name => _1)) }
      end

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

        defined(name) { raise Unsupported, "quint: unknown name #{name}" }
      end

      # A pure val or pure def reads no variable, and a lambda reads none
      # until it is called, so their value is the same in every state and is
      # evaluated once. Every other definition is evaluated on each read.
      def defined(name, &missing)
        @constant.fetch(name) do
          definition = @defs.fetch(name, &missing)
          value = eval(definition["expr"], {})
          constant = %w[pureval puredef].include?(definition["qualifier"]) || definition["expr"]["kind"] == "lambda"
          constant ? @constant[name] = value.freeze : value
        end
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
          # A definition is a lambda, or another operator's name (`def doubleOf = twice`).
          call(defined(op) { raise Unsupported, "quint: no evaluation for operator #{op}" }, args.map { eval(_1, env) })
        end
      end
  end
end
