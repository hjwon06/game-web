class CreateSalesOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :sales_orders do |t|
      t.string :so_no, null: false
      t.string :customer, null: false
      t.date :due_date
      t.string :status, null: false, default: "open"
      t.timestamptz :created_at, null: false, default: -> { "now()" }

      t.index :so_no, unique: true
      t.check_constraint "status IN ('open','partial','done')", name: "sales_orders_status_check"
    end
  end
end
