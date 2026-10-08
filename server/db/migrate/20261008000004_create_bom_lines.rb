class CreateBomLines < ActiveRecord::Migration[8.1]
  def change
    create_table :bom_lines do |t|
      t.references :product, null: false, foreign_key: true, index: false
      t.references :component, null: false, foreign_key: { to_table: :products }
      t.decimal :qty_per, precision: 14, scale: 3, null: false
      t.timestamps

      t.index [:product_id, :component_id], unique: true
      t.check_constraint "qty_per > 0", name: "bom_lines_qty_per_check"
      t.check_constraint "product_id <> component_id", name: "bom_lines_not_self_check"
    end
  end
end
