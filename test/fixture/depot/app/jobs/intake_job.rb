# Assigns each parcel of an intake to the next free compartment. A row is done
# when its parcel is in a compartment, and failed when the parcel is not
# waiting or no compartment is free. When the locker controller times out, the
# job stops and runs again later.
class IntakeJob < ApplicationJob
  retry_on LockerApi::TimedOut, wait: 1.minute, attempts: 10

  def perform(intake)
    intake.rows.each do |row|
      row.update(status: assign(row.parcel) ? "done" : "failed")
    end
    intake.update!(finished_at: Time.current)
  end

  private
    def assign(parcel)
      compartment = Compartment.free.first
      return false unless parcel&.waiting? && compartment

      Parcel.transaction { parcel.assign_to!(compartment) }
      true
    end
end
