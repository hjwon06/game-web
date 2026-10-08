# 예약(reservations): 작업이 가져가기로 한 재고. quant 기준(품목·로트·위치)으로 잡고 작업 1건에 1행이다.
# 가용 재고 = quants.qty - active 예약 합. active -> consumed(작업 완료) / released(작업 취소)는 작업 상태 변경과 같은 트랜잭션에서 한다.
# 작업이 prune 되면 예약도 같이 지워진다(on_delete cascade) — active 는 planned/started 작업에만 있어 지워질 일이 없다.
class CreateReservations < ActiveRecord::Migration[8.1]
  def change
    create_table :reservations do |t|
      t.references :task, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.references :product, null: false, foreign_key: true, index: false
      t.references :lot, null: true, foreign_key: true, index: false
      t.references :location, null: false, foreign_key: true, index: false
      t.decimal :qty, precision: 14, scale: 3, null: false
      t.string :status, null: false, default: "active"
      t.timestamps

      # 가용 재고 계산은 active 만 위치별로 합한다. 끝난 예약은 인덱스에 싣지 않는다.
      t.index %i[location_id product_id], where: "status = 'active'", name: "index_reservations_active_on_location_and_product"

      t.check_constraint "qty > 0", name: "reservations_qty_check"
      t.check_constraint "status IN ('active','consumed','released')", name: "reservations_status_check"
    end
  end
end
