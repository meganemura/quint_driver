require "stringio"
require_relative "../spec_helper"
require "quint_driver/hegel"

RSpec.describe "a lending shelf held to loans.qnt by Hegel" do
  settings = { test_cases: 100, seed: 1, suppress_health_check: %i[filter_too_much too_slow] }

  it "agrees with the model on every sequence Hegel chooses" do
    machine = QuintDriver.machine(LoansDriver.spec, driver: -> { LoansDriver.new }, invariants: %i[one_book_each])

    Hegel.test(**settings) { |tc| Hegel::Stateful.run(machine.new, tc) }
  end

  it "reports a broken system as the shortest sequence that breaks it" do
    machine = QuintDriver.machine(LoansDriver.spec, driver: -> { LoansDriver.new(BrokenLoans) })
    report = StringIO.new

    expect { Hegel.test(**settings, output: report) { |tc| Hegel::Stateful.run(machine.new, tc) } }
      .to raise_error(QuintDriver::Mismatch, /outcome: model \["Refused", "limit_reached"\], driver "Done"/)
    expect(report.string.scan(/^\s+(borrow\S*|give_back\S*) \{/).flatten).to eq(%w[borrow borrow_refused])
  end
end
