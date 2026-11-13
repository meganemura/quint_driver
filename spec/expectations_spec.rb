require_relative "spec_helper"

RSpec.describe "an expectation of unlimited.qnt, a spec of BrokenLoans as written" do
  unlimited = File.expand_path("../test/unlimited.qnt", __dir__)
  replay = lambda do |driver, invariants|
    spec = QuintDriver::Spec.new(unlimited, main: "unlimited")
    QuintDriver::Quint.simulate(unlimited, traces: 30, max_steps: 10, seed: "1") do |path|
      QuintDriver::Trace.replay(path, driver, spec:, invariants:)
    end
  end
  replay_line = __LINE__ - 3

  # This suite loads the gem from lib/, as a Gemfile's path: does, and RSpec
  # hides only frames under a gem directory.
  it "raises Violated, not Mismatch, from the line that called the replay, where the system agrees and the expectation breaks" do
    expect { replay.(LoansDriver.new(BrokenLoans), %w[one_book_each]) }.to raise_error(QuintDriver::Violated) { |error|
      expect(error).not_to be_a(QuintDriver::Mismatch)
      expect(error.message).to match(/\Aquint: the system agreed with the spec at every step, and the expectation `one_book_each` does not hold after step \d+ `borrow` \{.*\}\nsteps:\n  init \{\}\n/)
      expect(error.message).to match(/\nstate:\n  holder: \{"b1" => "\w*", "b2" => "\w*", "b3" => "\w*"\}\n  outcome: "Done"\ntrace: trace_\d+\.itf\.json of Quint\.simulate\(/)
      expect(RSpec.configuration.backtrace_formatter.format_backtrace(error.backtrace).first).to start_with("./spec/expectations_spec.rb:#{replay_line}:")
    }
  end

  it "replays every trace when the expectation holds in every state" do
    expect { replay.(LoansDriver.new(BrokenLoans), %w[lent_to_members]) }.not_to raise_error
  end

  it "yields only the traces that break the expectation under violate:, and says how many quint ran" do
    spec = QuintDriver::Spec.new(unlimited, main: "unlimited")
    broken = 0
    simulation = QuintDriver::Quint.simulate(unlimited, traces: 30, max_steps: 10, seed: "1", violate: "one_book_each") do |path|
      expect { QuintDriver::Trace.replay(path, LoansDriver.new(BrokenLoans), spec:, invariants: %w[one_book_each]) }.to raise_error(QuintDriver::Violated)
      broken += 1
    end

    expect(broken).to be > 1
    expect(simulation).to eq(QuintDriver::Quint::Simulation.new(traces: 30, violated: broken))
  end

  it "yields no trace and raises nothing under violate: when every trace keeps the expectation" do
    simulation = QuintDriver::Quint.simulate(unlimited, traces: 30, max_steps: 10, seed: "1", violate: "lent_to_members") { raise "no trace breaks it" }

    expect(simulation).to eq(QuintDriver::Quint::Simulation.new(traces: 30, violated: 0))
  end

  it "fails with a Mismatch where the system disagrees on the step that breaks the expectation" do
    expect { replay.(LoansDriver.new(Loans), %w[one_book_each]) }
      .to raise_error(QuintDriver::Mismatch, /, the driver differs from the trace\n(  .*\n)*  outcome: trace "Done", driver \["Refused", "limit_reached"\]\n/)
  end
end
