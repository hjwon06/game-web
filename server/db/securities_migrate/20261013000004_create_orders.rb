# 주문. seq 는 접수 순서(시간 우선)용 시퀀스 기본값이고 UNIQUE 다.
# 시장가는 price NULL, 지정가는 price > 0 — 둘을 CHECK 하나로 묶어 "시장가인데 가격이 있는" 행을 막는다.
class CreateOrders < ActiveRecord::Migration[8.1]
  def up
    execute "CREATE SEQUENCE orders_seq"

    create_table :orders do |t|
      t.string :client_key, null: false
      t.references :account, null: false, foreign_key: true
      t.references :asset, null: false, foreign_key: true
      t.string :side, null: false
      t.string :order_type, null: false
      t.bigint :price
      t.bigint :qty, null: false
      t.bigint :filled_qty, null: false, default: 0
      t.string :status, null: false
      t.bigint :seq, null: false, default: -> { "nextval('orders_seq')" }
      t.timestamptz :accepted_at, null: false, default: -> { "now()" }

      t.index :client_key, unique: true, name: "orders_client_key_uidx"
      t.index :seq, unique: true, name: "orders_seq_uidx"
      t.check_constraint "side IN ('buy','sell')", name: "orders_side_check"
      t.check_constraint "order_type IN ('limit','market')", name: "orders_order_type_check"
      # CHECK 는 NULL 이면 통과한다. 그래서 지정가는 IS NOT NULL 을 명시한다.
      # order_type 이 범위 밖이면 이 제약은 통과시키고 orders_order_type_check 가 잡는다.
      t.check_constraint "(order_type <> 'limit' OR (price IS NOT NULL AND price > 0)) AND (order_type <> 'market' OR price IS NULL)",
                         name: "orders_price_check"
      t.check_constraint "qty > 0", name: "orders_qty_check"
      t.check_constraint "filled_qty >= 0 AND filled_qty <= qty", name: "orders_filled_qty_check"
      t.check_constraint "status IN ('accepted','partially_filled','filled','cancelled','rejected')",
                         name: "orders_status_check"
    end

    execute "ALTER SEQUENCE orders_seq OWNED BY orders.seq"
  end

  def down
    drop_table :orders
    execute "DROP SEQUENCE IF EXISTS orders_seq"
  end
end
