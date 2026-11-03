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
