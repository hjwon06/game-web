class CreateProductionEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :production_events do |t|
      t.references :machine, null: false, foreign_key: true, index: false
      t.references :work_order, null: false, foreign_key: true, index: false
      t.timestamptz :bucket_start, null: false
      t.timestamptz :bucket_end, null: false
      t.integer :good_qty, null: false
      t.integer :defect_qty, null: false
      t.integer :machine_version, null: false

      t.index [:machine_id, :bucket_start], unique: true
      t.check_constraint "good_qty >= 0 AND defect_qty >= 0", name: "production_events_qty_check"
    end
  end
end
