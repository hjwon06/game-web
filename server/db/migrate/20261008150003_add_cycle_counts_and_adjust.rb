# 순환 실사(cycle count): 작업 종류 count, 이동 유형 adjust(재고 조정), 가상 위치 inventory_loss, 실사 기록 cycle_counts.
# 이동 유형 10번째(adjust)는 ⑦ 오더가 명시해서 더한다. 경로 표는 코드(Inventory::Move)라 여기서 바꾸지 않는다.
# 위치 inventory_loss 는 가상 위치(마이너스 허용)라 조정의 상대편이 된다. 위치 데이터는 Location.ensure_defaults! 와 같은 값이다.
class AddCycleCountsAndAdjust < ActiveRecord::Migration[8.1]
  OLD_MOVE_TYPES = %w[receive putaway feed issue produce qc_pass qc_fail pick ship].freeze
  NEW_MOVE_TYPES = (OLD_MOVE_TYPES + %w[adjust]).freeze
  OLD_TASK_KINDS = %w[unload putaway pick feed inspect load].freeze
  NEW_TASK_KINDS = (OLD_TASK_KINDS + %w[count]).freeze

  def up
    replace_check(:stock_moves, "stock_moves_move_type_check", "move_type", NEW_MOVE_TYPES)
    replace_check(:tasks, "tasks_kind_check", "kind", NEW_TASK_KINDS)

    execute <<~SQL
      INSERT INTO locations (code, name, kind, role, level, capacity_units, created_at, updated_at)
      VALUES ('inventory_loss', '재고 조정', 'virtual', 'inventory_loss', NULL, NULL, now(), now())
      ON CONFLICT (code) DO NOTHING
    SQL

    create_table :cycle_counts do |t|
      t.references :location, null: false, foreign_key: true, index: false
      t.references :product, null: false, foreign_key: true, index: false
      # 실사 작업이 prune 으로 지워져도 기록은 남는다.
      t.references :task, null: true, foreign_key: { on_delete: :nullify }, index: false
      t.decimal :system_qty, precision: 14, scale: 3, null: false
      t.decimal :counted_qty, precision: 14, scale: 3, null: false
      t.datetime :counted_at, null: false
      t.timestamps

      # "마지막 실사가 가장 오래된 칸"을 칸별 최근 시각으로 찾는다.
      t.index %i[location_id counted_at]
      t.index %i[task_id product_id], unique: true, where: "task_id IS NOT NULL", name: "index_cycle_counts_on_task_and_product"
      t.check_constraint "system_qty >= 0 AND counted_qty >= 0", name: "cycle_counts_qty_check"
    end
  end

  # adjust 이동이나 count 작업이 이미 있으면 CHECK 재생성이나 위치 삭제가 실패한다 — 원장은 append-only 라서 의도된 동작.
  def down
    drop_table :cycle_counts
    execute "DELETE FROM locations WHERE code = 'inventory_loss'"
    replace_check(:tasks, "tasks_kind_check", "kind", OLD_TASK_KINDS)
    replace_check(:stock_moves, "stock_moves_move_type_check", "move_type", OLD_MOVE_TYPES)
  end

  private

  def replace_check(table, name, column, values)
    remove_check_constraint table, name: name
    add_check_constraint table, "#{column} IN (#{values.map { |v| "'#{v}'" }.join(',')})", name: name
  end
end
