# A parcel the depot expects or holds. It waits until it is assigned to a
# compartment, and leaves when its receiver collects it.
class Parcel < ApplicationRecord
  belongs_to :compartment, optional: true

  validates :label, presence: true, uniqueness: true

  scope :waiting, -> { where(compartment_id: nil, collected_at: nil) }
  scope :assigned, -> { where.not(compartment_id: nil) }

  def waiting? = compartment_id.nil? && collected_at.nil?

  # Puts the parcel in the compartment and makes its pickup code open the door.
  def assign_to!(compartment)
    update!(compartment:, pickup_code: format("%06d", SecureRandom.random_number(1_000_000)))
    LockerApi.register(compartment.number, pickup_code)
  end

  # Hands the parcel to its receiver: the compartment is free again, and the
  # code no longer opens the door.
  def hand_over!
    number = compartment.number
    update!(compartment: nil, collected_at: Time.current)
    LockerApi.revoke(number)
  end
end
