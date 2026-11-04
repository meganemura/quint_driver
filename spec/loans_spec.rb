require_relative "spec_helper"

RSpec.describe "a lending shelf held to loans.qnt" do
  it "replays every trace Quint writes" do
    count = 0
    QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 20, max_steps: 20, seed: "1") do |path|
      QuintDriver::Trace.replay(path, LoansDriver.new)
      count += 1
    end

    expect(count).to eq(20)
  end

  # This suite loads the gem from lib/, as a Gemfile's path: does, and RSpec
  # hides only frames under a gem directory.
  it "prints a mismatch's backtrace from the line that called the replay, with no frame of the gem" do
    expect do
      QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 20, max_steps: 20, seed: "1") do |path|
        QuintDriver::Trace.replay(path, LoansDriver.new(BrokenLoans))
      end
    end.to raise_error(QuintDriver::Mismatch) { |error|
      expect(RSpec.configuration.backtrace_formatter.format_backtrace(error.backtrace).first).to start_with("./spec/loans_spec.rb:#{__LINE__ - 3}:")
      expect(error.backtrace).not_to include(start_with(File.expand_path("../lib", __dir__) + "/"))
    }
  end

  it "names the step, the steps and the trace where the driver's own code raised" do
    misspelled = Class.new(LoansDriver) { def step(action, picks) = action == "give_back" ? picks.fetch("book") : super }
    line = __LINE__ - 1

    expect do
      QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 20, max_steps: 20, seed: "1") do |path|
        QuintDriver::Trace.replay(path, misspelled.new)
      end
    end.to raise_error(QuintDriver::StepRaised) { |error|
      expect(error.message).to match(/\Aquint: at step \d+ `give_back` \{"b" => "b\d"\}, the step raised KeyError: key not found: "book"\nraised in: spec\/loans_spec\.rb:#{line}:in .*fetch'\nsteps:\n  init \{\}\n/)
      expect(error.message.lines.last).to match(/\Atrace: trace_\d+\.itf\.json of Quint\.simulate\(/)
      expect(error.cause).to be_a(KeyError)
    }
  end

  it "names the system's frame when the system beneath the driver raised" do
    unfinished = Class.new(Loans) { def give_back(book) = normalize(book) }
    line = __LINE__ - 1

    expect do
      QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 20, max_steps: 20, seed: "1") do |path|
        QuintDriver::Trace.replay(path, LoansDriver.new(unfinished))
      end
    end.to raise_error(QuintDriver::StepRaised, /, the step raised NoMethodError: .*\nraised in: spec\/loans_spec\.rb:#{line}:in .*give_back'\nsteps:\n/)
  end
end
