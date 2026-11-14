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

# Trace.replay reads an observed definition in the state quint wrote, the
# machine in the state the model stepped to; the two have to agree.
def test_the_model_reads_an_observed_definition_the_same_in_a_trace_s_state_as_after_its_own_steps
  { "operators" => %w[NUMS], "painting" => %w[shade red tint white], "loans" => %w[one_book_each nothing_on_loan two_on_loan] }.each do |main, names|
    file = main == "loans" ? LoansDriver::SPEC : OPERATORS
    spec = QuintDriver::Spec.new(file, main:)
    observing = Class.new { define_method(:initialize) { @model = spec.model }; define_method(:step) { |*move| @model.step(*move) }; define_method(:state) { @model.state.merge(@model.observe(names)) } }
    count = 0
    QuintDriver::Quint.simulate(file, main:, traces: 50, max_steps: 20, seed: "3") do |path|
      QuintDriver::Trace.replay(path, observing.new, spec:, observe: names)
      count += 1
    end

    assert_equal 50, count, main
  end
end

  def test_a_rule_names_the_domains_that_read_no_variable_and_no_earlier_pick
    fixed = ->(main) { QuintDriver::Spec.new(OPERATORS, main:).rules("step").to_h { [ _1.action, _1.fixed.sort ] } }

    assert_equal({ "pair" => %w[a], "unpair" => [] }, fixed.("pairing"))
    assert_equal({ "add" => [], "drop" => [], "reset" => [] }, fixed.("operators"))
    assert_equal [ %w[b m] ] * 2 + [ %w[b] ] * 2, LoansDriver.spec.rules("step").map { _1.fixed.sort }
  end

  def test_the_model_refuses_an_operator_it_does_not_evaluate_and_names_the_definition_that_holds_it
    error = assert_raises(QuintDriver::Unsupported) { unsupported.step("double", {}) }

    assert_equal "quint: no evaluation for operator powerset in subsets", error.message
    assert error.backtrace.first.start_with?("#{__FILE__}:"), "the test's own line leads, as it does for a Mismatch: #{error.backtrace.first}"
  end

  def test_the_model_names_the_action_that_draws_a_domain_it_cannot_evaluate
    rule = QuintDriver::Spec.new(OPERATORS, main: "unsupported").rules("step").find { _1.action == "resize" }
    stepped = assert_raises(QuintDriver::Unsupported) { unsupported.step("resize", { "s" => Set[1] }) }
    listed = assert_raises(QuintDriver::Unsupported) { unsupported.moves(rule) }

    assert_equal [ "quint: no evaluation for operator powerset in picking" ] * 2, [ stepped.message, listed.message ]
  end

def test_the_model_names_the_action_that_writes_a_domain_above_a_nested_choice
  rule = QuintDriver::Spec.new(OPERATORS, main: "unsupported").rules("step").find { _1.action == "grow" }
  error = assert_raises(QuintDriver::Unsupported) { unsupported.moves(rule) }

  assert_equal "quint: no evaluation for operator powerset in step", error.message
end

def test_the_model_names_no_definition_for_a_node_it_is_handed_directly
    error = assert_raises(QuintDriver::Unsupported) { unsupported.value({ "kind" => "name", "name" => "nowhere" }) }

    assert_equal "quint: no evaluation for the name nowhere outside any definition; no definition, variable or parameter has it",
                 error.message
  end

  def test_the_model_refuses_an_operation_quint_leaves_undefined_and_names_the_action_that_holds_it
    halve = assert_raises(QuintDriver::Unsupported) { unsupported.try("halve") }
    parity = assert_raises(QuintDriver::Unsupported) { unsupported.try("parity") }
    first = assert_raises(QuintDriver::Unsupported) { unsupported.try("first") }
    overwrite = assert_raises(QuintDriver::Unsupported) { unsupported.try("overwrite") }
    bump = assert_raises(QuintDriver::Unsupported) { unsupported.try("bumpMissing") }
    pairs = assert_raises(QuintDriver::Unsupported) { unsupported.try("pairUp") }

    assert_equal "quint: no evaluation for -1 / 2 in halve; Quint documents no rounding for a negative operand", halve.message
    assert_equal "quint: no evaluation for -1 % 2 in parity; Quint documents no rounding for a negative operand", parity.message
    assert_equal "quint: no evaluation for head of an empty list in first; Quint leaves it undefined", first.message
    assert_equal "quint: no evaluation for set(_, 2) in overwrite; the map has no such key", overwrite.message
    assert_equal "quint: no evaluation for setBy(_, \"b\") in bumpMissing; the map has no such key", bump.message
    assert_equal "quint: no evaluation for setToMap of pairs that share a key in pairUp; Quint leaves it undefined", pairs.message
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

  def test_the_ruby_model_follows_quint_on_a_pick_of_an_option
    spec = QuintDriver::Spec.new(OPERATORS, main: "approval")
    count = 0
    QuintDriver::Quint.simulate(OPERATORS, main: "approval", traces: 20, max_steps: 10, seed: "5") do |path|
      QuintDriver::Trace.replay(path, spec.model)
      count += 1
    end

    assert_equal 20, count
  end

  def test_the_ruby_model_follows_quint_on_a_pick_of_false_and_on_the_set_bool
    spec = QuintDriver::Spec.new(OPERATORS, main: "switch")
    picks = Set.new
    QuintDriver::Quint.simulate(OPERATORS, main: "switch", traces: 20, max_steps: 10, seed: "1") do |path|
      QuintDriver::Trace.replay(path, spec.model).each { picks << [ _1.action, _1.picks["b"] ] }
    end

    assert_includes picks, [ "flip", false ]
    assert_equal Set[false, true], picks.select { |action, _| action == "press" }.to_set { |_, b| b }
  end

  def test_the_model_refuses_to_list_int_or_nat
    rule = QuintDriver::Spec.new(OPERATORS, main: "unsupported").rules("step").find { _1.action == "count" }
    error = assert_raises(QuintDriver::Unsupported) { unsupported.moves(rule) }

    assert_equal "quint: no evaluation for the name Nat in step; Nat is infinite, so no move can list its picks; draw from a finite set such as 0.to(9)", error.message
    int = assert_raises(QuintDriver::Unsupported) { unsupported.value("Int") }
    assert_equal "quint: no evaluation for the name Int outside any definition; Int is infinite, so no move can list its picks; draw from a finite set such as 0.to(9)", int.message
  end

  def test_the_model_refuses_a_pick_outside_its_domain
    model = QuintDriver::Spec.new(OPERATORS, main: "painting").model
    model.step("init", {})

    error = assert_raises(QuintDriver::Mismatch) { model.step("paint", { "c" => "Green" }) }
    assert_equal %(quint: the model cannot pick c = "Green" for paint), error.message
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

  # Quint reads an action's val only when the action needs it, and a def
  # with a parameter inside an action is a local operator. The model does the
  # same, so it follows Quint's traces and refuses the move Quint never takes
  # instead of failing on the val that guard keeps from being read.
  def test_an_action_s_vals_are_read_when_needed_and_its_defs_are_local_operators
    nested = File.expand_path("nested.qnt", __dir__)
    spec = QuintDriver::Spec.new(nested)
    QuintDriver::Quint.simulate(nested, traces: 20, max_steps: 5, seed: "1") { QuintDriver::Trace.replay(_1, spec.model) }
    model = spec.model
    model.step("init", {})

    assert_equal({ "n" => 1, "owner" => { 1 => "a" } }, model.step("take", { "k" => 1 }))
    assert_equal 'quint: the model refused take {"k" => 2}', assert_raises(QuintDriver::Mismatch) { model.step("take", { "k" => 2 }) }.message
  end

  def test_a_spec_lists_its_expectations_in_the_order_it_declares_them
    assert_equal %w[one_book_each nothing_on_loan two_on_loan], LoansDriver.spec.expectations
    assert_empty QuintDriver::Spec.new(File.expand_path("nested.qnt", __dir__)).expectations
  end

  def test_a_spec_without_main_reads_the_module_named_after_the_file
    assert_equal LoansDriver.spec.rules("step").map(&:action), QuintDriver::Spec.new(LoansDriver::SPEC).rules("step").map(&:action)
  end

  def test_a_model_comes_only_from_a_spec
    error = assert_raises(NoMethodError) { QuintDriver::Model.new([ { "kind" => "def", "name" => "init" } ], []) }

    assert_match(/private method .new. called/, error.message)
  end

  def test_checking_states_is_not_part_of_the_api
    refute_respond_to QuintDriver, :compare!
    assert_equal %i[Hold Mismatch Model Quint QuintFailed Spec StepRaised Targets Trace Unsupported VERSION Violated], QuintDriver.constants.sort
  end

  def test_which_trace_a_simulate_block_is_yielding_is_not_part_of_the_api
    assert_equal %i[command compile evaluator simulate test], QuintDriver::Quint.singleton_methods.sort
  end

  private
    def unsupported
      QuintDriver::Spec.new(OPERATORS, main: "unsupported").model.tap { _1.step("init", {}) }
    end
end
