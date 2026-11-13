# The sender took a waiting parcel back, so the depot no longer expects it.
class WithdrawalsController < ApplicationController
  def create
    parcel = Parcel.waiting.find(params[:parcel_id])
    parcel.destroy!
    redirect_to parcels_path, notice: "#{parcel.label} was withdrawn."
  end
end
