ActiveRecord::Schema[8.1].define(version: 2026_09_14_101500) do
  create_table "compartments", force: :cascade do |t|
    t.integer "number", null: false
    t.timestamps
    t.index [ "number" ], unique: true
  end

  create_table "parcels", force: :cascade do |t|
    t.string "label", null: false
    t.integer "compartment_id"
    t.string "pickup_code"
    t.datetime "collected_at"
    t.timestamps
    t.index [ "label" ], unique: true
    t.index [ "compartment_id" ], unique: true
  end

  create_table "intakes", force: :cascade do |t|
    t.datetime "finished_at"
    t.timestamps
  end

  create_table "intake_rows", force: :cascade do |t|
    t.integer "intake_id", null: false
    t.integer "parcel_id", null: false
    t.string "status", null: false, default: "pending"
    t.timestamps
    t.index [ "intake_id" ]
  end
end
