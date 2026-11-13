# One door of the locker wall. It is free while no parcel is in it.
class Compartment < ApplicationRecord
  has_one :parcel

  validates :number, presence: true, uniqueness: true

  scope :free, -> { where.missing(:parcel).order(:number) }
end
