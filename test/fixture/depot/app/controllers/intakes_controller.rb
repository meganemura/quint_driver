# The desk pastes a delivery's manifest, one parcel label per line, and
# IntakeJob assigns the parcels to compartments.
class IntakesController < ApplicationController
  def create
    labels = params[:manifest].to_s.split
    intake = Intake.transaction do
      Intake.create!.tap do |created|
        labels.each { |label| created.rows.create!(parcel: Parcel.find_by!(label:)) }
      end
    end
    IntakeJob.perform_later(intake)
    redirect_to parcels_path, notice: "The intake of #{labels.size} parcels has started."
  end
end
