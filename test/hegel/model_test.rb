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

class ListPropertyTest < Minitest::Test
  include Hegel::Syntax::Methods

  # Each list operator gives what Quint's builtin docs say on any list, and is
  # refused exactly where the docs leave it undefined. slice also takes
  # i == l.length(), which both of Quint's evaluators answer with [].
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
        app("range", int(i), int(j)) => i <= j ? Array.new(j - i) { i + _1 } : :undefined
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

  private
    def app(opcode, *args) = { "kind" => "app", "opcode" => opcode, "args" => args }
    def ref(name) = { "kind" => "name", "name" => name }
    def int(value) = { "kind" => "int", "value" => value }
    def l = ref("l")
end
