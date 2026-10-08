# ③b: 이동 유형 feed(raw 칸 → line_side)·pick(fg 칸 → shipping)을 원장 CHECK 에 더하고, 위치 line_side 를 넣는다.
# 경로 표(Inventory::Move::ALLOWED_PATHS)는 코드라 여기서 바꾸지 않는다.
# 타임스탬프가 locations 계층(20261008130001)·tasks(20261008130003) 마이그레이션보다 앞이라, 그 테이블·컬럼이 아직 없는
# 새 DB 에서는 위치와 tasks 인덱스를 넣지 않는다. 위치는 130001 이 부르는 Location.ensure_defaults! 가 용량과 함께 만든다.
# (새 DB 는 보통 structure.sql 로 올리므로 이 경로를 타지 않는다.)
class AddLineSideAndFeedPickMoves < ActiveRecord::Migration[8.1]
  OLD_TYPES = %w[receive putaway issue produce qc_pass qc_fail ship].freeze
  NEW_TYPES = %w[receive putaway feed issue produce qc_pass qc_fail pick ship].freeze

  def up
    replace_move_type_check(NEW_TYPES)
    # 출하 계획(Simulation::Shipping)이 수주 라인(ref)별로 pick·load 작업을 10초마다 센다. ref 인덱스가 없으면 7일치 done 을 훑는다.
    add_index :tasks, %i[ref_type ref_id], name: "index_tasks_on_ref" if table_exists?(:tasks)

    return unless column_exists?(:locations, :capacity_units)

    execute <<~SQL
      INSERT INTO locations (code, name, kind, role, level, capacity_units, created_at, updated_at)
      VALUES ('line_side', '라인 공급대', 'physical', 'line_side', 'warehouse', 800, now(), now())
      ON CONFLICT (code) DO NOTHING
    SQL
  end

  # feed·pick 이동이나 line_side 재고가 이미 있으면 CHECK 재생성이나 위치 삭제가 FK 로 실패한다 — 원장은 append-only 라서 의도된 동작.
  def down
    execute "DELETE FROM locations WHERE code = 'line_side'"
    replace_move_type_check(OLD_TYPES)
    remove_index :tasks, name: "index_tasks_on_ref" if index_name_exists?(:tasks, "index_tasks_on_ref")
  end

  private

  def replace_move_type_check(types)
    remove_check_constraint :stock_moves, name: "stock_moves_move_type_check"
    add_check_constraint :stock_moves, "move_type IN (#{types.map { |t| "'#{t}'" }.join(',')})", name: "stock_moves_move_type_check"
  end
end
