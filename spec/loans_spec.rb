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
end
