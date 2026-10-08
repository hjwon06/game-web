# 현재고 = 이동의 집계 캐시. 물리 위치 마이너스는 CHECK 로 막는다:
# negative_allowed 는 가상 위치 행에만 true (서비스가 location.kind 로 채움, A2).
class CreateQuants < ActiveRecord::Migration[8.1]
  def change
    create_table :quants do |t|
      t.references :product, null: false, foreign_key: true, index: false
      t.references :lot, foreign_key: true
      t.references :location, null: false, foreign_key: true
      t.decimal :qty, precision: 14, scale: 3, null: false, default: 0
      t.boolean :negative_allowed, null: false, default: false
      t.timestamps

      # lot_id NULL 도 유일해야 하므로 COALESCE (PG 버전 무관)
      t.index "product_id, COALESCE(lot_id, 0), location_id", unique: true, name: "index_quants_unique_slot"
      t.check_constraint "qty >= 0 OR negative_allowed", name: "quants_physical_non_negative_check"
    end
  end
end
