require_relative "test_helper"
require "stringio"

class MachineTest < Minitest::Test
  SETTINGS = { test_cases: 100, seed: 1, suppress_health_check: %i[filter_too_much too_slow] }.freeze

  %i[rule rotate].each do |choose|
    define_method(:"test_#{choose}_passes_a_system_that_follows_the_spec") do
      machine = machine(Loans, choose)

      Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(machine.new, tc) }
    end

    define_method(:"test_#{choose}_shrinks_a_broken_system_to_two_moves") do
      machine = machine(BrokenLoans, choose)
      report = StringIO.new

      error = assert_raises(QuintConnectHegel::Mismatch) do
        Hegel.test(**SETTINGS, output: report) { |tc| Hegel::Stateful.run(machine.new, tc) }
      end

      moves = report.string.scan(/^\s+(borrow\S*|give_back\S*) \{.*\}$/).flatten
      assert_equal %w[borrow borrow_refused], moves
      assert_match(/outcome: model \["Refused", "limit_reached"\], driver "Done"/, error.message)
    end
  end

  def test_an_invariant_holds_on_every_state_hegel_reaches
    machine = QuintConnectHegel.machine(LoansDriver.spec, driver: -> { LoansDriver.new }, invariants: %i[one_book_each])

    Hegel.test(**SETTINGS) { |tc| Hegel::Stateful.run(machine.new, tc) }
  end

  def test_a_broken_invariant_fails_at_the_first_state_that_breaks_it
    machine = QuintConnectHegel.machine(LoansDriver.spec, driver: -> { LoansDriver.new }, invariants: %i[nothing_on_loan])

    error = assert_raises(QuintConnectHegel::Mismatch) do
      Hegel.test(**SETTINGS, output: StringIO.new) { |tc| Hegel::Stateful.run(machine.new, tc) }
    end
    assert_equal "quint: the model broke `nothing_on_loan`", error.message
  end

  private
    def machine(system, choose)
      QuintConnectHegel.machine(LoansDriver.spec, driver: -> { LoansDriver.new(system) }, choose:)
    end
end
