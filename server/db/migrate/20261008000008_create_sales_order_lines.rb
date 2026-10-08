# 출하량 컬럼은 두지 않는다 (stock_moves ship 에서 계산).
class CreateSalesOrderLines < ActiveRecord::Migration[8.1]
  def change
    create_table :sales_order_lines do |t|
      t.references :sales_order, null: false, foreign_key: true
      t.references :product, null: false, foreign_key: true
      t.decimal :ordered_qty, precision: 14, scale: 3, null: false
      t.timestamps

      t.check_constraint "ordered_qty > 0", name: "sales_order_lines_ordered_qty_check"
    end
  end
end
