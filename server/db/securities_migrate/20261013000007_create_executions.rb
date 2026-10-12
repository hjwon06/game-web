# 체결. settlement_id 는 결제에 묶이기 전까지 NULL 이다.
class CreateExecutions < ActiveRecord::Migration[8.1]
  def change
    create_table :executions do |t|
      t.references :asset, null: false, foreign_key: true
      t.references :buy_order, null: false, foreign_key: { to_table: :orders }
      t.references :sell_order, null: false, foreign_key: { to_table: :orders }
      t.bigint :price, null: false
      t.bigint :qty, null: false
      t.timestamptz :executed_at, null: false, default: -> { "now()" }
      t.date :trade_date, null: false
      t.date :settle_date, null: false
      t.references :settlement, foreign_key: true

      t.index [:trade_date, :settle_date]
      t.check_constraint "price > 0", name: "executions_price_check"
      t.check_constraint "qty > 0", name: "executions_qty_check"
    end
  end
end
