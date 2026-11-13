FactoryBot.define do
  factory :compartment do
    sequence(:number)
  end

  factory :parcel do
    sequence(:label) { "DP-#{_1}" }
  end

  factory :intake

  factory :intake_row do
    intake
    parcel
  end
end
