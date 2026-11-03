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

  def test_the_model_lists_the_moves_each_rule_allows_now
    spec = LoansDriver.spec
    model = spec.model
    model.step("init", {})
    moves = spec.rules("step").to_h { |rule| [ rule.action, model.moves(rule).map { |action, picks, _| [ action, picks ] } ] }

    lend = %w[m1 m2].product(%w[b1 b2 b3]).map { |m, b| [ "borrow", { "m" => m, "b" => b } ] }
    refuse = %w[b1 b2 b3].map { [ "give_back_refused", { "b" => _1 } ] }
    assert_equal({ "borrow" => lend, "borrow_refused" => [], "give_back" => [], "give_back_refused" => refuse }, moves)

    action, picks, after = model.moves(spec.rules("step").first).first
    model.enter(after)
    assert_equal({ "b1" => "m1", "b2" => "", "b3" => "" }, model.state["holder"])
    assert_equal [ "borrow", { "m" => "m1", "b" => "b1" } ], [ action, picks ]
  end

  def test_the_model_refuses_a_disabled_step
    model = LoansDriver.spec.model
    model.step("init", {})

    assert_raises(QuintDriver::Mismatch) { model.step("give_back", { "b" => "b1" }) }
  end

  def test_the_ruby_model_follows_quint_on_a_pick_of_a_sum_type
    spec = QuintDriver::Spec.new(OPERATORS, main: "painting")
    count = 0
    QuintDriver::Quint.simulate(OPERATORS, main: "painting", traces: 20, max_steps: 10, seed: "5") do |path|
      QuintDriver::Trace.replay(path, spec.model)
      count += 1
    end

    assert_equal 20, count
  end

  def test_the_model_refuses_a_pick_outside_its_domain
    model = QuintDriver::Spec.new(OPERATORS, main: "painting").model
    model.step("init", {})

    error = assert_raises(QuintDriver::Mismatch) { model.step("paint", { "c" => "Green" }) }
    assert_match(/c/, error.message)
    assert_match(/"Green"/, error.message)
  end

  def test_the_model_refuses_a_move_that_lacks_a_pick
    model = LoansDriver.spec.model
    model.step("init", {})

    error = assert_raises(QuintDriver::Unsupported) { model.step("borrow", { "m" => "m1" }) }
    assert_equal "quint: borrow needs a pick for b, and the move gives none", error.message
  end

  def test_the_model_refuses_a_move_that_leaves_a_variable_unassigned
    model = QuintDriver::Spec.new(OPERATORS, main: "unassigned").model
    model.step("init", {})

    error = assert_raises(QuintDriver::Unsupported) { model.step("bump", {}) }
    assert_equal "quint: bump leaves m unassigned", error.message
  end

  def test_a_model_comes_only_from_a_spec
    error = assert_raises(NoMethodError) { QuintDriver::Model.new([ { "kind" => "def", "name" => "init" } ], []) }

    assert_match(/private method .new. called/, error.message)
  end

  def test_checking_states_is_not_part_of_the_api
    refute_respond_to QuintDriver, :compare!
    assert_equal %i[Mismatch Model Quint QuintFailed Spec Trace Unsupported VERSION], QuintDriver.constants.sort
  end

  private
    def unsupported
      QuintDriver::Spec.new(OPERATORS, main: "unsupported").model.tap { _1.step("init", {}) }
    end
end
