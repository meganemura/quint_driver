class ParcelsController < ApplicationController
  def index
    @parcels = Parcel.includes(:compartment).order(:label)
    @free = Compartment.free.count
    @intake = Intake.order(:id).last
  end
end
