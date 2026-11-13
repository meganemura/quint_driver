# Hunts for what the depot does and its operator does not expect. depot.qnt
# models the code as it is written, so the app follows every trace, and an
# expectation that breaks on a trace the app followed is a bug suspect.
#
# As committed, the app has four bugs planted, one behind each expectation, and
# fixed.patch takes them out:
#   taken_compartment_has_live_code     AssignmentsController#create rescues the time-out inside its transaction
#   free_compartment_has_no_code        ReleasesController#create rescues it inside its transaction too
#   done_row_stays_done                 IntakeJob#perform goes through every row again when it is retried
#   finished_job_leaves_no_row_pending  IntakeJob#perform ignores that a row whose parcel is gone does not save
require "rails_helper"
require "quint_driver/hegel"
require_relative "depot_driver"

RSpec.describe "The depot, held to depot.qnt", type: :request do
  qnt = Rails.root.join("spec/quint/depot.qnt")
  expectations = %w[taken_compartment_has_live_code free_compartment_has_no_code done_row_stays_done finished_job_leaves_no_row_pending]
  # Only the spec remembers which rows were done before, so the driver reports no everDone.
  ignore = %w[everDone]

  let(:spec) { QuintDriver::Spec.new(qnt, main: "depot") }
  let(:driver) { DepotDriver.new(self) }

  before do
    allow(LockerApi).to receive(:register) { |number, code| driver.register(number, code) }
    allow(LockerApi).to receive(:revoke) { |number| driver.revoke(number) }
  end

  def rolled_back
    ActiveRecord::Base.transaction(requires_new: true, joinable: false) do
      yield
      raise ActiveRecord::Rollback
    end
  end

  it "does what the spec says on every trace Quint writes" do
    reached = Set.new
    QuintDriver::Quint.simulate(qnt, traces: 30, max_steps: 12, seed: "1") do |path|
      rolled_back { QuintDriver::Trace.replay(path, driver, ignore:).each { reached << _1.action } }
    end

    expect(reached).to include("assignParcel", "release", "withdraw", "takeIn", "runJob")
  end

  # Quint yields only the traces that break the expectation, each ending where
  # it breaks. The replay names the expectation again: without invariants: it
  # passes, because the app follows the trace.
  expectations.each do |expectation|
    it "keeps #{expectation} on the traces Quint aims at it" do
      simulation = QuintDriver::Quint.simulate(qnt, traces: 200, max_steps: 12, seed: "1", violate: expectation) do |path|
        rolled_back { QuintDriver::Trace.replay(path, driver, spec:, invariants: [ expectation ], ignore:) }
      end
      expect(simulation.never).to be_empty
    end
  end

  # The steps a Violated printed, pasted as they are, pin that suspect as one
  # example that needs no quint run.
  it "keeps free_compartment_has_no_code when a release times out" do
    QuintDriver.replay_steps(spec, driver, <<~STEPS, invariants: %w[free_compartment_has_no_code], ignore:)
      init {}
      assignParcel {"offline" => 2, "p" => "p3"}
      release {"offline" => 1, "p" => "p3"}
    STEPS
  end

  it "keeps every expectation on the sequences Hegel chooses" do
    machine = QuintDriver.machine(spec, driver: -> { driver }, invariants: expectations, ignore:)
    Hegel.test(test_cases: 50, seed: 1, suppress_health_check: %i[filter_too_much too_slow]) do |tc|
      rolled_back { Hegel::Stateful.run(machine.new, tc) }
    end
  end
end
