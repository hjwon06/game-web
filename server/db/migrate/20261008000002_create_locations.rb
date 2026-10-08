class CreateLocations < ActiveRecord::Migration[8.1]
  def up
    create_table :locations do |t|
      t.string :code, null: false
      t.string :name, null: false
      t.string :kind, null: false
      t.string :role
      t.timestamps

      t.index :code, unique: true
      t.check_constraint "kind IN ('physical','virtual')", name: "locations_kind_check"
    end

    execute <<~SQL
      INSERT INTO locations (code, name, kind, role, created_at, updated_at) VALUES
        ('supplier',   '공급처',     'virtual',  'supplier',   now(), now()),
        ('customer',   '고객',       'virtual',  'customer',   now(), now()),
        ('production', '생산',       'virtual',  'production', now(), now()),
        ('scrap',      '폐기',       'virtual',  'scrap',      now(), now()),
        ('receiving',  '입고대',     'physical', 'receiving',  now(), now()),
        ('raw_store',  '자재창고',   'physical', 'storage',    now(), now()),
        ('qc',         '검사대',     'physical', 'qc',         now(), now()),
        ('fg_store',   '완제품창고', 'physical', 'storage',    now(), now()),
        ('shipping',   '출하대',     'physical', 'shipping',   now(), now())
    SQL
  end

  def down
    drop_table :locations
  end
end
