# One line of a delivery's manifest: a parcel, and whether IntakeJob found it
# a compartment.
class IntakeRow < ApplicationRecord
  STATUSES = %w[pending done failed].freeze

  belongs_to :intake
  belongs_to :parcel

  validates :parcel, presence: true
  validates :status, inclusion: { in: STATUSES }
end
