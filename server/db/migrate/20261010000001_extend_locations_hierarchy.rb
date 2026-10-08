# 위치를 트리로 확장한다: warehouse > zone > rack > bin. 기존 9개 위치는 그대로(코드·id·kind·role 불변).
# 가상 위치(supplier 등)는 level NULL, 물리 루트 5개(receiving/raw_store/qc/fg_store/shipping)는 'warehouse'.
# capacity_units 는 NULL 이면 무제한이다(기존 9개). 칸(bin)만 값을 갖는다.
# 구역·랙·칸 시드는 Location.ensure_defaults! 가 맡는다 — 여기서 부른다(재실행 안전).
class ExtendLocationsHierarchy < ActiveRecord::Migration[8.1]
  PHYSICAL_ROOTS = %w[receiving raw_store qc fg_store shipping].freeze

  def up
    add_reference :locations, :parent, foreign_key: { to_table: :locations }, null: true, index: true
    add_column :locations, :level, :string
    add_column :locations, :capacity_units, :integer

    add_check_constraint :locations, "level IS NULL OR level IN ('warehouse','zone','rack','bin')", name: "locations_level_check"
    add_check_constraint :locations, "capacity_units IS NULL OR capacity_units > 0", name: "locations_capacity_units_check"
    add_check_constraint :locations, "parent_id IS NULL OR parent_id <> id", name: "locations_parent_not_self_check"

    execute "UPDATE locations SET level = 'warehouse' WHERE code IN (#{PHYSICAL_ROOTS.map { |c| "'#{c}'" }.join(',')})"

    Location.reset_column_information
    Location.ensure_defaults!
  end

  # 칸·랙·구역을 먼저 지워야 컬럼을 뗄 수 있다. 칸에 재고(quants)나 이동(stock_moves)이 걸려 있으면 FK 로 실패한다 — 의도된 동작.
  def down
    execute "DELETE FROM locations WHERE parent_id IS NOT NULL AND level = 'bin'"
    execute "DELETE FROM locations WHERE parent_id IS NOT NULL AND level = 'rack'"
    execute "DELETE FROM locations WHERE parent_id IS NOT NULL AND level = 'zone'"
    remove_check_constraint :locations, name: "locations_parent_not_self_check"
    remove_check_constraint :locations, name: "locations_capacity_units_check"
    remove_check_constraint :locations, name: "locations_level_check"
    remove_column :locations, :capacity_units
    remove_column :locations, :level
    remove_reference :locations, :parent, foreign_key: { to_table: :locations }, index: true
  end
end
