class CreateProducts < ActiveRecord::Migration[8.1]
  def change
    create_table :products do |t|
      t.string :sku, null: false
      t.string :name, null: false
      t.string :uom, null: false # 품목당 1개 고정, 단위 변환 없음
      t.string :kind, null: false
      t.timestamps

      t.index :sku, unique: true
      t.check_constraint "kind IN ('raw','wip','fg')", name: "products_kind_check"
      t.check_constraint "btrim(uom) <> ''", name: "products_uom_check"
    end
  end
end
