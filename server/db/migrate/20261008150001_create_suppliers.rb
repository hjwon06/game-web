# 공급사(suppliers)와 공급사가 대는 품목(supplier_products). 리드타임 = 발주에서 트럭 도착까지 걸리는 초.
# 한 품목을 여러 공급사가 댈 수 있게 (공급사, 품목) 쌍만 유니크로 둔다. 발주할 공급사는 Supplier.for_product 가 id 순 첫 공급사로 고른다.
class CreateSuppliers < ActiveRecord::Migration[8.1]
  def change
    create_table :suppliers do |t|
      t.string :code, null: false
      t.string :name, null: false
      t.integer :lead_time_seconds, null: false
      t.timestamps

      t.index :code, unique: true
      t.check_constraint "lead_time_seconds > 0", name: "suppliers_lead_time_check"
    end

    create_table :supplier_products do |t|
      t.references :supplier, null: false, foreign_key: true, index: false
      t.references :product, null: false, foreign_key: true, index: true
      t.timestamps

      t.index %i[supplier_id product_id], unique: true
    end
  end
end
