# 자산: 현금(KRW) 1 + 종목. 금액·수량은 전부 bigint 정수(원 단위)다.
class CreateAssets < ActiveRecord::Migration[8.1]
  def change
    create_table :assets do |t|
      t.string :code, null: false
      t.string :name, null: false
      t.string :kind, null: false
      t.bigint :base_price

      t.index :code, unique: true, name: "assets_code_uidx"
      t.check_constraint "kind IN ('cash','equity')", name: "assets_kind_check"
      # CHECK 는 NULL 이면 통과한다. 그래서 종목은 IS NOT NULL 을 명시한다.
      # kind 가 범위 밖이면 이 제약은 통과시키고 assets_kind_check 가 잡는다(한 위반에 제약 하나).
      t.check_constraint "(kind <> 'equity' OR (base_price IS NOT NULL AND base_price > 0)) AND (kind <> 'cash' OR base_price IS NULL)",
                         name: "assets_base_price_check"
    end
  end
end
