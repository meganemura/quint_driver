require_relative "spec_helper"

RSpec.describe "a driver that leaves out a variable of the spec" do
  holder_only = Class.new(LoansDriver) { def state = super.slice("holder") }
  replay = lambda do |driver, **options|
    QuintDriver::Quint.simulate(LoansDriver::SPEC, traces: 20, max_steps: 20, seed: "1") do |path|
      QuintDriver::Trace.replay(path, driver, **options)
    end
  end

  it "fails the replay at init and names the variable" do
    expect { replay.(holder_only.new) }
      .to raise_error(QuintDriver::Mismatch, /\Aquint: after step 0 `init` \{\}, the driver differs from the trace\n  outcome: trace "Done", but the driver's state leaves outcome out; /)
  end

  it "passes when ignore: names the variable the driver only reads" do
    expect { replay.(holder_only.new, ignore: %w[outcome]) }.not_to raise_error
  end
end
