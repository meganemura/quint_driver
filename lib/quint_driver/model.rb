module QuintDriver
  # Evaluates a spec's JSON IR inside the Ruby process, so a Hegel step costs
  # no call to another process. It covers the operators a command-per-action
  # spec uses and raises Unsupported on any other, so a spec that outgrows it
  # fails loudly instead of being judged wrongly. It answers the driver
  # protocol too, which is how it is held to Quint: replay Quint's own traces
  # through it.
  class Model
    Variant = Struct.new(:tag, :value)

    # +within+ names the definition that holds the lambda, so an operator its
    # body cannot evaluate is reported where the spec writes it.
    Closure = Struct.new(:params, :body, :env, :within)

    # Spec#model is the one way to build a model: the evaluator trusts the
    # shape of quint's compiled IR and checks none of it.
    private_class_method :new

    # +owners+ names the definition that writes each IR node, by its id.
    def initialize(declarations, rules, owners)
      @owners = owners
      @defs = declarations.select { _1["kind"] == "def" }.to_h { [ _1["name"], _1 ] }
      @vars = declarations.select { _1["kind"] == "var" }.map { _1["name"] }
      @rules = rules.to_h { [ _1.action, _1 ] }
      @state = {}
      @constant = {}
      @within = nil
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
      enter(try(action, args) || raise(Mismatch, "quint: the model refused #{action} #{Agreement.show(picks)}"))
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
      return nil unless inside(name) { eval(expr, env) }

      missing = @vars - @next.keys
      raise Unsupported, "quint: #{name} leaves #{missing.join(', ')} unassigned" if missing.any?

      @next
    end

    def enter(state) = @state = state

    # Every [action, picks, next state] that +rule+, a Spec::Rule, allows
    # now, in a fixed order, so the same draw means the same move from the
    # same state.
    def moves(rule)
      picks_of(rule, rule.domains.to_a, {}).filter_map do |picks|
        after = try(rule.action, rule.args.map { value(_1, picks) })
        [ rule.action, picks, after ] if after
      end
    end

    # A refusal names the definition that writes +node_or_name+, such as the
    # action a domain or an argument of a rule is written in, or says the node
    # is outside any definition when no definition of the spec holds it.
    def value(node_or_name, env = {})
      node = node_or_name.is_a?(String) ? { "kind" => "name", "name" => node_or_name } : node_or_name
      inside(@owners[node["id"]]) { eval(node, env) }
    end

    # Each definition +names+ names, by name, as a plain value.
    def observe(names) = names.to_h { [ _1, Model.plain(value(_1)) ] }

    # A value as Trace.decode gives it, so a driver reads an Option the same
    # on a replay and under the machine: nil for None, the value for Some.
    def self.plain(value)
      case value
      when Variant
        case value.tag
        when "None" then nil
        when "Some" then plain(value.value)
        else value.value == [] ? value.tag : [ value.tag, plain(value.value) ]
        end
      when Set then value.to_set { plain(_1) }
      when Hash then value.to_h { |k, v| [ plain(k), plain(v) ] }
      when Array then value.map { plain(_1) }
      else value
      end
    end

    private
      def picks_of(rule, domains, picks)
        return [ picks ] if domains.empty?

        (name, domain), *rest = domains
        value(domain, picks).to_a.sort_by(&:to_s).flat_map { picks_of(rule, rest, picks.merge(name => _1)) }
      end

      def eval(node, env)
        case node["kind"]
        when "str", "int", "bool" then node["value"]
        when "name" then lookup(node["name"], env)
        when "lambda" then Closure.new(node["params"].map { _1["name"] }, node["expr"], env, @within)
        when "let"
          definition = node["opdef"]
          eval(node["expr"], env.merge(definition["name"] => eval(definition["expr"], env)))
        when "app" then apply(node["opcode"], node["args"], env)
        else refuse("IR kind #{node['kind']}")
        end
      end

      def lookup(name, env)
        return env[name] if env.key?(name)
        return @state.fetch(name) if @vars.include?(name)

        defined(name) { refuse("the name #{name}", "no definition, variable or parameter has it") }
      end

      # A pure val or pure def reads no variable, and a lambda reads none
      # until it is called, so their value is the same in every state and is
      # evaluated once. Every other definition is evaluated on each read.
      def defined(name, &missing)
        @constant.fetch(name) do
          definition = @defs.fetch(name, &missing)
          value = inside(name) { eval(definition["expr"], {}) }
          constant = %w[pureval puredef].include?(definition["qualifier"]) || definition["expr"]["kind"] == "lambda"
          constant ? @constant[name] = value.freeze : value
        end
      end

      def call(closure, args)
        inside(closure.within) { eval(closure.body, closure.env.merge(closure.params.zip(args).to_h)) }
      end

      def inside(name)
        outer, @within = @within, name
        yield
      ensure
        @within = outer
      end

      def refuse(what, why = nil)
        raise Unsupported, "quint: no evaluation for #{what} #{@within ? "in #{@within}" : 'outside any definition'}#{"; #{why}" if why}"
      end

      # Quint's builtin docs leave these undefined, and its two evaluators do
      # not always agree on them (range(3, 1) is [] in one and [3, 2] in the
      # other), so the model refuses them rather than pick an answer.
      def undefined(what) = refuse(what, "Quint leaves it undefined")

      def index!(list, i, op)
        return i if i.between?(0, list.size - 1)

        undefined("#{op}(_, #{i}) on a list of length #{list.size}")
      end

      def nonempty!(list, op) = list.empty? ? undefined("#{op} of an empty list") : list

      def keyed!(map, key, op) = map.key?(key) || refuse("#{op}(_, #{key.inspect})", "the map has no such key")

      # Quint documents no rounding: its evaluators truncate / and % toward
      # zero, and Ruby's Integer#/ and #% floor, so only operands where the
      # two agree are evaluated.
      def divide(a, b, op)
        refuse("#{a} #{op} #{b}", "Quint documents no rounding for a negative operand") if a.negative? || b.negative?
        b.zero? ? undefined("#{a} #{op} 0") : a.public_send(op, b)
      end

      def apply(op, args, env)
        case op
        when "actionAll", "and" then args.all? { eval(_1, env) }
        when "or" then args.any? { eval(_1, env) }
        when "implies" then !eval(args[0], env) || eval(args[1], env)
        when "ite" then eval(args[eval(args[0], env) ? 1 : 2], env)
        when "assign" then @next[args[0]["name"]] = eval(args[1], env); true
        else operate(op, args.map { eval(_1, env) })
        end
      end

      # Every other operator reads all of its arguments, so they are evaluated
      # once, before it runs.
      def operate(op, values)
        a, b, c = values
        case op
        when "not" then !a
        when "eq", "iff" then a == b
        when "neq" then a != b
        when "igt" then a > b
        when "igte" then a >= b
        when "ilt" then a < b
        when "ilte" then a <= b
        when "iadd" then a + b
        when "isub" then a - b
        when "imul" then a * b
        when "idiv" then divide(a, b, "/")
        when "imod" then divide(a, b, "%")
        when "iuminus" then -a
        when "to" then a <= b ? (a..b).to_set : undefined("#{a}.to(#{b})")
        # A set's fold order is unspecified, so Quint leaves a fold whose
        # operator is not associative and commutative undefined.
        when "fold", "foldl" then a.reduce(b) { |acc, x| call(c, [ acc, x ]) }
        # The builtin docs leave foldr out, but both evaluators fold from the
        # right and pass the element first.
        when "foldr" then a.reverse.reduce(b) { |acc, x| call(c, [ x, acc ]) }
        when "List", "Tup" then values
        when "append" then a + [ b ]
        when "concat" then a + b
        when "head" then nonempty!(a, "head").first
        when "tail" then nonempty!(a, "tail").drop(1)
        when "length" then a.size
        when "nth" then a[index!(a, b, "nth")]
        when "indices" then (0...a.size).to_set
        when "replaceAt" then a.dup.tap { _1[index!(a, b, "replaceAt")] = c }
        when "slice"
          # The docs also leave i == l.length() undefined, but both evaluators
          # answer slice(l, l.length(), l.length()) with [], which the docs'
          # own reading (from i inclusive to j exclusive) gives, and a spec
          # that drops a list's last element needs it.
          0 <= b && b <= c && c <= a.size ? a[b...c] : undefined("slice(_, #{b}, #{c}) on a list of length #{a.size}")
        when "range" then a <= b ? (a...b).to_a : undefined("range(#{a}, #{b})")
        when "select" then a.select { call(b, [ _1 ]) }
        when "Set" then values.to_set
        when "contains" then a.include?(b)
        when "in" then b.include?(a)
        when "union" then a | b
        when "intersect" then a & b
        when "exclude" then a - b
        when "subseteq" then a.subset?(b)
        when "size" then a.size
        when "exists" then a.any? { call(b, [ _1 ]) }
        when "forall" then a.all? { call(b, [ _1 ]) }
        when "filter" then a.select { call(b, [ _1 ]) }.to_set
        when "map" then a.to_set { call(b, [ _1 ]) }
        when "Map" then values.to_h
        when "put", "with" then a.merge(b => c)
        when "mapBy" then a.to_h { [ _1, call(b, [ _1 ]) ] }
        when "set" then a.merge(b => c) if keyed!(a, b, "set")
        when "setBy" then a.merge(b => call(c, [ a[b] ])) if keyed!(a, b, "setBy")
        # Which of two pairs with one key wins depends on the set's order.
        when "setToMap" then a.to_h.tap { undefined("setToMap of pairs that share a key") if _1.size < a.size }
        when "get" then a.fetch(b) { refuse("get(_, #{b.inspect})", "the map has no such key") }
        when "keys" then a.keys.to_set
        when "item" then a.fetch(b - 1)
        when "Rec" then values.each_slice(2).to_h
        when "field" then a.fetch(b)
        when "variant" then Variant.new(a, b)
        when "matchVariant"
          arm = values.drop(1).each_slice(2).find { |label, _| [ a.tag, "_" ].include?(label) }
          call(arm[1], [ a.value ])
        else
          # A definition is a lambda, or another operator's name (`def doubleOf = twice`).
          call(defined(op) { refuse("operator #{op}") }, values)
        end
      end
  end
end
