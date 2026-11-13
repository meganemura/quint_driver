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

  # unlimited.qnt models BrokenLoans as written, so only the expectation
  # finds the second book a member borrows.
  it "raises Violated, not Mismatch, where the system agrees and an expectation does not hold" do
    unlimited = QuintDriver::Spec.new(File.expand_path("../../test/unlimited.qnt", __dir__), main: "unlimited")
    machine = QuintDriver.machine(unlimited, driver: -> { LoansDriver.new(BrokenLoans) }, invariants: %i[one_book_each])

    hegel_line = __LINE__ + 1
    expect { Hegel.test(**settings, output: StringIO.new) { |tc| Hegel::Stateful.run(machine.new, tc) } }
      .to raise_error(QuintDriver::Violated) { |error|
        expect(error).not_to be_a(QuintDriver::Mismatch)
        expect(error.message).to start_with("quint: the system agreed with the spec at every step, and the expectation `one_book_each` " \
                                            "does not hold after step 2 `borrow` {\"b\" => \"b2\", \"m\" => \"m1\"}\nsteps:\n  init {}\n" \
                                            "  borrow {\"b\" => \"b1\", \"m\" => \"m1\"}\n  borrow {\"b\" => \"b2\", \"m\" => \"m1\"}\nstate:\n")
        expect(RSpec.configuration.backtrace_formatter.format_backtrace(error.backtrace).first).to start_with("./spec/hegel/loans_spec.rb:#{hegel_line}:")
      }
  end

  it "names the move and the shrunk steps where the driver's own code raised" do
    misspelled = Class.new(LoansDriver) { def step(action, picks) = action.start_with?("give_back") ? picks.fetch("book") : super }
    line = __LINE__ - 1
    machine = QuintDriver.machine(LoansDriver.spec, driver: -> { misspelled.new })

    expect { Hegel.test(**settings, output: StringIO.new) { |tc| Hegel::Stateful.run(machine.new, tc) } }
      .to raise_error(QuintDriver::StepRaised, /\Aquint: at step 1 `give_back\S*` \{"b" => "b\d"\}, the step raised KeyError: key not found: "book"\nraised in: spec\/hegel\/loans_spec\.rb:#{line}:in .*fetch'\nsteps:\n  init \{\}\n  give_back\S* \{"b" => "b\d"\}\z/)
  end

  it "fails a driver that disagrees at init before Hegel takes a step" do
    busy = Class.new(LoansDriver) { def state = super.merge("outcome" => "Busy") }
    machine = QuintDriver.machine(LoansDriver.spec, driver: -> { busy.new })
    report = StringIO.new

    expect { Hegel.test(**settings, output: report) { |tc| Hegel::Stateful.run(machine.new, tc) } }
      .to raise_error(QuintDriver::Mismatch, /\Aquint: after step 0 `init` \{\}, /)
    expect(report.string).not_to match(/Step \d/)
  end
end
