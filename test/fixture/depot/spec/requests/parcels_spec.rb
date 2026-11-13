require "rails_helper"

RSpec.describe "Parcels" do
  before do
    allow(LockerApi).to receive(:register)
    allow(LockerApi).to receive(:revoke)
  end

  it "assigns a waiting parcel to the first free compartment" do
    create(:compartment, number: 1)
    parcel = create(:parcel)

    post parcel_assignment_path(parcel)

    expect(parcel.reload.compartment.number).to eq(1)
    expect(LockerApi).to have_received(:register).with(1, parcel.pickup_code)
  end

  it "frees the compartment when the parcel is collected" do
    parcel = create(:parcel, compartment: create(:compartment, number: 4))

    post parcel_release_path(parcel)

    expect(parcel.reload).to have_attributes(compartment: nil, collected_at: be_present)
    expect(LockerApi).to have_received(:revoke).with(4)
  end

  it "assigns the parcels of a manifest in the background" do
    create(:compartment, number: 1)
    create(:parcel, label: "DP-1")
    create(:parcel, label: "DP-2")

    post intakes_path, params: { manifest: "DP-1\nDP-2" }
    IntakeJob.perform_now(Intake.last)

    expect(Intake.last.rows.map(&:status)).to eq(%w[done failed])
    expect(Intake.last.finished_at).to be_present
  end

  it "lists each parcel with what the desk can do next" do
    create(:parcel, label: "DP-1", compartment: create(:compartment))
    create(:parcel, label: "DP-2", collected_at: 1.hour.ago)
    create(:parcel, label: "DP-3")
    create(:intake_row, parcel: Parcel.last)

    get parcels_path

    expect(response.body).to include("DP-1", "Collected", "DP-2", "about 1 hour ago", "DP-3", "Assign", "Withdraw", "1 pending")
  end
end
