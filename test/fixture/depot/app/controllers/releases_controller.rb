# The desk releases a compartment when the receiver has picked the parcel up.
class ReleasesController < ApplicationController
  def create
    parcel = Parcel.assigned.find(params[:parcel_id])
    number = parcel.compartment.number

    Parcel.transaction do
      parcel.hand_over!
      flash.notice = "#{parcel.label} was collected. Compartment #{number} is free."
    rescue LockerApi::TimedOut
      flash.alert = "Compartment #{number} did not answer. Try again."
    end
    redirect_to parcels_path
  end
end
