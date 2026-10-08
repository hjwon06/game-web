# 재주문점(Odoo orderpoint). 자재 보유 분수(coverage = 보유 / 분당 수요)가 min_minutes 이상이면 발주하지 않고,
# 발주할 때는 max_minutes 까지 채운다. 규칙이 없는 자재는 예전처럼 coverage 가 가장 작은 것부터 발주 후보가 된다.
class CreateReorderRules < ActiveRecord::Migration[8.1]
  def change
    create_table :reorder_rules do |t|
      t.references :product, null: false, foreign_key: true, index: false
      t.integer :min_minutes, null: false
      t.integer :max_minutes, null: false
      t.boolean :active, null: false, default: true
      t.timestamps

      t.index :product_id, unique: true
      t.check_constraint "min_minutes >= 0 AND max_minutes >= min_minutes", name: "reorder_rules_minutes_check"
    end
  end
end
