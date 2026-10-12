# 주문 1건당 묶음 1행(order_id UNIQUE). 체결마다 qty 가 줄어 0 까지 간다.
class CreateHolds < ActiveRecord::Migration[8.1]
  def change
    create_table :holds do |t|
      t.references :order, null: false, foreign_key: true, index: false
      t.references :account, null: false, foreign_key: true
      t.references :asset, null: false, foreign_key: true
      t.bigint :qty, null: false
      t.timestamptz :released_at

      t.index :order_id, unique: true, name: "holds_order_uidx"
      t.check_constraint "qty >= 0", name: "holds_qty_check"
    end
  end
end
