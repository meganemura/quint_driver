require_relative "../test_helper"
require "quint_driver/hegel"

class ModelPropertyTest < Minitest::Test
  include Hegel::Syntax::Methods
  SETTINGS = { test_cases: 100, seed: 1, suppress_health_check: %i[filter_too_much too_slow] }.freeze
  OPERATORS = File.expand_path("../operators.qnt", __dir__)

  # A model keeps what it evaluated in earlier states; a new model entered
  # into the same state has kept nothing. They must read every definition
  # without parameters, and allow every move, the same.
  [ [ LoansDriver::SPEC, "loans" ], [ OPERATORS, "operators" ], [ OPERATORS, "painting" ] ].each do |path, main|
    define_method(:"test_a_model_reads_#{main}_in_each_state_as_a_new_model_does") do
      spec = QuintDriver::Spec.new(path, main:)
      rules = spec.rules("step")
      names = spec.declarations.select { _1["kind"] == "def" && _1["qualifier"] != "action" && _1["expr"]["kind"] != "lambda" }
                  .map { _1["name"] }
      read = ->(model) { [ names.map { model.value(_1) }, rules.map { model.moves(_1) } ] }

      Hegel.test(**SETTINGS) do |tc|
        model = spec.model
        model.step("init", {})
        tc.draw(integers(min_value: 0, max_value: 20)).times do
          moves = rules.flat_map { model.moves(_1) }
          break if moves.empty?

          read.(model)
          after = tc.draw(sampled_from(moves)).last
          model.enter(after)
          fresh = spec.model.tap { _1.enter(after) }
          assert_equal read.(fresh), read.(model)
        end
      end
    end
  end
end

class FixedDomainPropertyTest < Minitest::Test
  include Hegel::Syntax::Methods
  SETTINGS = { test_cases: 100, seed: 1, suppress_health_check: %i[filter_too_much too_slow] }.freeze
  OPERATORS = File.expand_path("../operators.qnt", __dir__)

  # The machine evaluates a fixed domain once, so it must be the same set in
  # every state a model reaches and after every pick drawn before it.
  [ [ LoansDriver::SPEC, "loans" ], [ OPERATORS, "operators" ], [ OPERATORS, "painting" ], [ OPERATORS, "pairing" ] ].each do |path, main|
    define_method(:"test_a_fixed_domain_of_#{main}_is_one_set_in_every_state_and_after_every_pick") do
      spec = QuintDriver::Spec.new(path, main:)
      rules = spec.rules("step")
      first = spec.model.tap { _1.step("init", {}) }
      fixed = rules.to_h { |rule| [ rule, rule.fixed.to_h { [ _1, first.value(rule.domains[_1], {}, within: rule.within) ] } ] }

      Hegel.test(**SETTINGS) do |tc|
        model = spec.model
        model.step("init", {})
        tc.draw(integers(min_value: 0, max_value: 20)).times do
          moves = rules.flat_map { model.moves(_1) }
          break if moves.empty?

          rules.each do |rule|
            model.moves(rule).each do |_, picks, _|
              fixed[rule].each { |name, set| assert_equal set, model.value(rule.domains[name], picks.except(name), within: rule.within) }
            end
          end
          model.enter(tc.draw(sampled_from(moves)).last)
        end
      end
    end
  end
end

class ListPropertyTest < Minitest::Test
  include Hegel::Syntax::Methods

  # Each list operator gives what Quint's builtin docs say on any list, and is
  # refused exactly where the docs leave it undefined. slice also takes
  # i == l.length(), which both of Quint's evaluators answer with [].
  # foldr is in neither the builtin docs nor builtin.qnt, but both evaluators
  # define it the same way: [4, 5, 6].foldr(0, (x, acc) => acc * 10 + x) is
  # 654 under --backend rust and typescript, and [].foldr(z, f) is z.
  def test_the_list_operators_agree_with_quints_docs_on_every_list
    model = QuintDriver::Spec.new(File.expand_path("../operators.qnt", __dir__), main: "operators").model
    ints = integers(min_value: -2, max_value: 9)

    Hegel.test(test_cases: 300, seed: 1) do |tc|
      list, other = tc.draw(arrays(ints, max_size: 6)), tc.draw(arrays(ints, max_size: 3))
      i, j, x = tc.draw(integers(min_value: -1, max_value: 7)), tc.draw(integers(min_value: -1, max_value: 7)), tc.draw(ints)
      inside = (0...list.size).cover?(i)
      expected = {
        app("length", l) => list.size,
        app("indices", l) => Set.new(0...list.size),
        app("append", l, int(x)) => [ *list, x ],
        app("concat", l, ref("m")) => [ *list, *other ],
        app("head", l) => list.empty? ? :undefined : list[0],
        app("tail", l) => list.empty? ? :undefined : list[1..],
        app("nth", l, int(i)) => inside ? list[i] : :undefined,
        app("replaceAt", l, int(i), int(x)) => inside ? list.each_with_index.map { |e, k| k == i ? x : e } : :undefined,
        app("slice", l, int(i), int(j)) => i >= 0 && i <= j && j <= list.size ? list.drop(i).take(j - i) : :undefined,
        app("range", int(i), int(j)) => i <= j ? Array.new(j - i) { i + _1 } : :undefined,
        app("foldr", l, int(x), digits) => list.reverse.reduce(x) { |acc, e| acc * 10 + e }
      }
      expected.each do |node, want|
        got = begin
          model.value(node, { "l" => list, "m" => other })
        rescue QuintDriver::Unsupported
          :undefined
        end
        assert_equal want, got, "#{node['opcode']} #{list.inspect} i=#{i} j=#{j} x=#{x}"
      end
    end
  end

  # Both of Quint's evaluators truncate / and % toward zero, Ruby floors, and
  # Quint's docs define neither on a negative operand, so the model answers
  # only where the operands are not negative and the divisor is not zero.
  # Probed on quint 0.33.0: -7 % 2 is -1 under --backend rust and typescript,
  # 7 % -2 is 1, and 7 % 0 is a runtime error.
  def test_division_and_remainder_answer_only_on_operands_both_evaluators_agree_on
    model = QuintDriver::Spec.new(File.expand_path("../operators.qnt", __dir__), main: "operators").model

    Hegel.test(test_cases: 300, seed: 1) do |tc|
      a, b = tc.draw(integers(min_value: -9, max_value: 9)), tc.draw(integers(min_value: -9, max_value: 9))
      truncated = b.zero? ? nil : (a.abs / b.abs) * (a * b).then { _1.negative? ? -1 : 1 }
      expected = { "idiv" => truncated, "imod" => truncated && a - b * truncated }
      expected.each do |opcode, want|
        got = begin
          model.value(app(opcode, int(a), int(b)))
        rescue QuintDriver::Unsupported
          :refused
        end
        assert_equal(a.negative? || b.negative? || b.zero? ? :refused : want, got, "#{a} #{opcode} #{b}")
      end
    end
  end

  private
    def app(opcode, *args) = { "kind" => "app", "opcode" => opcode, "args" => args }
    def ref(name) = { "kind" => "name", "name" => name }
    def int(value) = { "kind" => "int", "value" => value }
    def l = ref("l")
    def digits = { "kind" => "lambda", "params" => [ { "name" => "x" }, { "name" => "acc" } ], "expr" => app("iadd", app("imul", ref("acc"), int(10)), ref("x")) }
end
