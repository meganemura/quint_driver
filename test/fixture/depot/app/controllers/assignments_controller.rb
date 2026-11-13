# The desk assigns a waiting parcel to the next free compartment.
class AssignmentsController < ApplicationController
  def create
    parcel = Parcel.waiting.find(params[:parcel_id])
    compartment = Compartment.free.first
    return redirect_to(parcels_path, alert: "No compartment is free.") unless compartment

    Parcel.transaction do
      parcel.assign_to!(compartment)
      flash.notice = "#{parcel.label} is in compartment #{compartment.number}."
    rescue LockerApi::TimedOut
      flash.alert = "Compartment #{compartment.number} did not answer. Try again."
    end
    redirect_to parcels_path
  end
end
