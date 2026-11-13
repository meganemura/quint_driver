# One delivery: a row for each parcel on its manifest. IntakeJob assigns the
# parcels and sets finished_at when it has gone through every row.
class Intake < ApplicationRecord
  has_many :rows, -> { order(:id) }, class_name: "IntakeRow", dependent: :destroy
end
