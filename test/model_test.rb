require_relative "test_helper"

class ModelTest < Minitest::Test
  OPERATORS = File.expand_path("operators.qnt", __dir__)

  def test_the_ruby_model_follows_every_trace_quint_writes
    count = 0
    QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 200, max_steps: 30, seed: "7") do |path|
      QuintDriver::Trace.replay(path, LoansDriver.spec.model)
      count += 1
    end

    assert_equal 200, count
  end

  def test_the_ruby_model_follows_quint_on_every_operator_it_evaluates
    spec = QuintDriver::Spec.new(OPERATORS, main: "operators")
    count = 0
    QuintDriver::Quint.simulate(OPERATORS, traces: 100, max_steps: 20, seed: "3") do |path|
      QuintDriver::Trace.replay(path, spec.model)
      count += 1
    end

    assert_equal 100, count
  end

  def test_the_model_refuses_an_operator_it_does_not_evaluate
    model = unsupported

    assert_raises(QuintDriver::Unsupported) { model.step("double", {}) }
  end

  def test_the_model_refuses_an_action_that_leaves_a_variable_unassigned
    model = unsupported

    assert_raises(QuintDriver::Unsupported) { model.try("bump") }
  end

  def test_the_model_refuses_a_trace_that_names_no_action_of_step
    model = QuintDriver::Spec.new(OPERATORS, main: "countdown").model

    error = assert_raises(QuintDriver::Unsupported) do
      QuintDriver::Quint.simulate(OPERATORS, main: "countdown", traces: 1, max_steps: 1, seed: "1") do |path|
        QuintDriver::Trace.replay(path, model)
      end
    end
    assert_match(/any \{/, error.message)
  end

  def test_the_model_knows_which_actions_are_enabled
    model = LoansDriver.spec.model
    model.step("init", {})

    refute_nil model.try("borrow", %w[m1 b1])
    assert_nil model.try("borrow_refused", %w[m1 b1])
    assert_nil model.try("give_back", %w[b1])
  end

  def test_the_model_refuses_a_disabled_step
    model = LoansDriver.spec.model
    model.step("init", {})

    assert_raises(QuintDriver::Mismatch) { model.step("give_back", { "b" => "b1" }) }
  end

  private
    def unsupported
      QuintDriver::Spec.new(OPERATORS, main: "unsupported").model.tap { _1.step("init", {}) }
    end
end
