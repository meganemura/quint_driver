require_relative "../test_helper"
require "quint_driver/hegel"
require "stringio"

class MachineTest < Minitest::Test
  SETTINGS = { test_cases: 100, seed: 1, suppress_health_check: %i[filter_too_much too_slow] }.freeze

  %i[rule rotate].each do |choose|
    define_method(:"test_#{choose}_passes_a_system_that_follows_the_spec") do
      machine = machine(Loans, choose)

      Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(machine.new, tc) }
    end

    define_method(:"test_#{choose}_draws_no_pick_from_an_empty_set") do
      spec = QuintDriver::Spec.new(File.expand_path("../operators.qnt", __dir__), main: "operators")
      machine = QuintDriver.machine(spec, driver: -> { spec.model }, choose:)

      Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(machine.new, tc) }
    end

    define_method(:"test_#{choose}_hands_a_driver_plain_picks_of_a_sum_type") do
      spec = QuintDriver::Spec.new(File.expand_path("../operators.qnt", __dir__), main: "painting")
      machine = QuintDriver.machine(spec, driver: -> { spec.model }, choose:)

      Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(machine.new, tc) }
    end

    define_method(:"test_#{choose}_stops_a_sequence_where_no_move_is_enabled") do
      spec = QuintDriver::Spec.new(File.expand_path("../operators.qnt", __dir__), main: "countdown")
      machine = QuintDriver.machine(spec, driver: -> { spec.model }, choose:)

      Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(machine.new, tc) }
    end

    define_method(:"test_#{choose}_shrinks_a_broken_system_to_two_moves") do
      machine = machine(BrokenLoans, choose)
      report = StringIO.new

      error = assert_raises(QuintDriver::Mismatch) do
        Hegel.test(**SETTINGS, output: report) { |tc| Hegel::Stateful.run(machine.new, tc) }
      end

      moves = report.string.scan(/^\s+(borrow\S*|give_back\S*) \{.*\}$/).flatten
      assert_equal %w[borrow borrow_refused], moves
      assert_match(/outcome: model \["Refused", "limit_reached"\], driver "Done"/, error.message)
      assert_equal [ "init", *moves ], error.message[/^steps:\n((?:  .*\n?)+)/, 1].to_s.lines.map { _1.split.first }
      assert_match(/^  borrow \{"b" => "b\d", "m" => "m\d"\}$/, error.message, "picks print in the order a replay prints them")
      names = report.string.scan(/^\s+([a-z]+)_\d+ = /).flatten.uniq.sort
      assert_equal(choose == :rule ? %w[b m] : %w[move rule], names)
    end
  end

  def test_the_system_runs_a_sequence_it_agreed_on_only_once
    runs = []
    recording = Class.new(LoansDriver) do
      define_method(:initialize) { |*args| super(*args); runs << (@moves = []) }
      define_method(:step) { |action, picks| @moves << [ action, picks ]; super(action, picks) }
    end
    machine = QuintDriver.machine(LoansDriver.spec, driver: -> { recording.new })

    Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(machine.new, tc) }

    assert_operator runs.size, :>, 1
    assert_equal runs.uniq, runs
  end

  def test_an_invariant_holds_on_every_state_hegel_reaches
    machine = QuintDriver.machine(LoansDriver.spec, driver: -> { LoansDriver.new }, invariants: %i[one_book_each])

    Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(machine.new, tc) }
  end

  def test_an_invariant_is_checked_on_every_state_a_move_reaches
    events = []
    spec = LoansDriver.spec.clone
    spec.define_singleton_method(:model) do |step|
      super(step).tap do |model|
        model.define_singleton_method(:enter) { |after| events << [ model, :move ]; super(after) }
        model.define_singleton_method(:value) { |name, *rest, **options| events << [ model, :check ] if name == "one_book_each"; super(name, *rest, **options) }
      end
    end
    machine = QuintDriver.machine(spec, driver: -> { LoansDriver.new }, invariants: %i[one_book_each])

    Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(machine.new, tc) }

    # The model that gives the driver's first state takes init and is never checked.
    after_moves = events.group_by(&:first).values.select { _1.size > 1 }.flat_map do |model_events|
      kinds = model_events.map(&:last)
      kinds.each_index.select { kinds[_1] == :move }.map { kinds[_1 + 1] }
    end
    assert_operator after_moves.size, :>, 100
    assert_equal [ :check ], after_moves.uniq
  end

  def test_a_broken_invariant_fails_at_the_first_state_that_breaks_it
    machine = QuintDriver.machine(LoansDriver.spec, driver: -> { LoansDriver.new }, invariants: %i[nothing_on_loan])

    error = assert_raises(QuintDriver::Mismatch) do
      Hegel.test(**SETTINGS, output: StringIO.new) { |tc| Hegel::Stateful.run(machine.new, tc) }
    end
    assert_equal "quint: the model broke `nothing_on_loan`", error.message
  end

  def test_the_adapter_adds_only_the_machine_to_quint_driver
    assert_equal %i[machine], QuintDriver.singleton_methods.sort
  end

  private
    def machine(system, choose)
      QuintDriver.machine(LoansDriver.spec, driver: -> { LoansDriver.new(system) }, choose:)
    end
end
