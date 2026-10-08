# 발주(purchase_orders)와 발주 라인. 입고 트럭은 이제 발주에서 시작한다: confirmed -> (리드타임) -> arrived -> (하차 완료) -> done.
# arrived_at 은 "최근 10분에 도착한 발주 수"(received_trucks_10m)를 세기 위한 컬럼이다.
# 라인의 입고량은 (qty_received <= qty_ordered) 를 DB 가 지킨다. 하차 작업이 라인을 ref 로 가리키므로 tasks 쪽 변경은 없다.
class CreatePurchaseOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :purchase_orders do |t|
      t.string :po_no, null: false
      t.references :supplier, null: false, foreign_key: true, index: false
      t.string :status, null: false, default: "confirmed"
      t.datetime :ordered_at, null: false
      t.datetime :expected_at, null: false
      t.datetime :arrived_at
      t.timestamps

      t.index :po_no, unique: true
      # 도착 판정은 confirmed 중 expected_at 이 지난 것만 본다. 끝난 발주는 인덱스에 싣지 않는다.
      t.index :expected_at, where: "status = 'confirmed'", name: "index_purchase_orders_confirmed_on_expected_at"
      t.index :arrived_at, where: "arrived_at IS NOT NULL", name: "index_purchase_orders_on_arrived_at"
      t.check_constraint "status IN ('confirmed','arrived','done','cancelled')", name: "purchase_orders_status_check"
    end

    create_table :purchase_order_lines do |t|
      t.references :purchase_order, null: false, foreign_key: true, index: true
      t.references :product, null: false, foreign_key: true, index: false
      t.decimal :qty_ordered, precision: 14, scale: 3, null: false
      t.decimal :qty_received, precision: 14, scale: 3, null: false, default: 0
      t.timestamps

      t.check_constraint "qty_ordered > 0", name: "purchase_order_lines_ordered_check"
      t.check_constraint "qty_received >= 0", name: "purchase_order_lines_received_check"
      t.check_constraint "qty_received <= qty_ordered", name: "purchase_order_lines_received_le_ordered_check"
    end
  end
end
