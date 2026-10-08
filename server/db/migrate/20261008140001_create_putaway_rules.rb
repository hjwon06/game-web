# 적치 규칙(putaway_rules): "이 품목은 이 구역·랙에 먼저 쌓는다"를 코드가 아니라 데이터로 둔다.
# product_id NULL = 전 품목. priority 는 작을수록 먼저(1~100). location 은 구역 또는 랙이고, 그 하위 칸이 후보다.
# 규칙은 몇 건 안 되는 설정 테이블이라 Ops::Putaway 가 매 호출 통째로 읽는다(인덱스는 중복 방지용 하나뿐).
class CreatePutawayRules < ActiveRecord::Migration[8.1]
  # 운영 DB 는 db:seed 없이 migrate 만 해도 규칙이 있어야 입고가 멈추지 않는다. 품목·위치가 없으면 0건 삽입이라 안전하다.
  # 같은 값이 PutawayRule::DEFAULTS 에도 있다(시드·테스트용). 바꿀 때 둘을 같이 바꾼다.
  SEED_ROWS = [
    ["RAW-STEEL", "RAW-A-01", 10], ["RAW-BOLT", "RAW-A-02", 10], ["RAW-PACK", "RAW-A-03", 10], [nil, "RAW-A-04", 90],
    [nil, "FG-A-01", 50], [nil, "FG-A-02", 50], [nil, "FG-A-03", 50], [nil, "FG-A-04", 50]
  ].freeze

  def up
    create_table :putaway_rules do |t|
      t.references :product, null: true, foreign_key: true, index: false
      t.references :location, null: false, foreign_key: true, index: false
      t.integer :priority, null: false, default: 50
      t.boolean :active, null: false, default: true
      t.timestamps

      t.check_constraint "priority BETWEEN 1 AND 100", name: "putaway_rules_priority_check"
    end
    add_index :putaway_rules, "COALESCE(product_id, 0), location_id", unique: true, name: "index_putaway_rules_unique_scope"

    SEED_ROWS.each do |sku, location_code, priority|
      execute <<~SQL
        INSERT INTO putaway_rules (product_id, location_id, priority, active, created_at, updated_at)
        SELECT p.id, l.id, #{priority}, TRUE, NOW(), NOW()
        FROM locations l LEFT JOIN products p ON p.sku = #{sku ? connection.quote(sku) : 'NULL'}
        WHERE l.code = #{connection.quote(location_code)} AND (#{sku ? 'p.id IS NOT NULL' : 'TRUE'})
        ON CONFLICT DO NOTHING
      SQL
    end
  end

  def down
    drop_table :putaway_rules
  end
end
