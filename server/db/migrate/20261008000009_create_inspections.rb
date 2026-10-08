class CreateInspections < ActiveRecord::Migration[8.1]
  def change
    create_table :inspections do |t|
      t.references :lot, null: false, foreign_key: true
      t.references :work_order, null: false, foreign_key: true
      t.string :result, null: false
      t.decimal :defect_qty, precision: 14, scale: 3, null: false, default: 0
      t.timestamptz :inspected_at, null: false, default: -> { "now()" }
      t.references :stock_move, null: false, foreign_key: true, index: { unique: true }
      t.timestamps

      t.check_constraint "result IN ('pass','fail')", name: "inspections_result_check"
      t.check_constraint "defect_qty >= 0", name: "inspections_defect_qty_check"
    end
  end
end
