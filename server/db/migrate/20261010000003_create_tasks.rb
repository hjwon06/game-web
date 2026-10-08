# 작업(tasks): 일이 시작~완료 시각을 가진 단위로 일어난다. 재고 이동은 완료 순간 stock_move 1건으로만 남는다.
# seq 는 전역 시퀀스(tasks_seq)를 트리거가 INSERT/UPDATE 마다 새로 배정한다 — update_all·raw SQL 로 바꿔도 빠지지 않는다.
# 주의(소비자): nextval 순서와 커밋 순서는 다르다. seq 로 증분을 읽는 쪽은 마지막 seq 에서 여유 구간을 두고 다시 읽는다.
class CreateTasks < ActiveRecord::Migration[8.1]
  def up
    execute "CREATE SEQUENCE tasks_seq"

    create_table :tasks do |t|
      t.string :kind, null: false
      t.string :status, null: false, default: "planned"
      t.references :resource, null: true, foreign_key: true, index: false
      # 품목·로트·위치 FK 는 인덱스를 만들지 않는다. 부모 행을 지우는 일이 없고, 일은 짧게 보존되는 테이블이라 쓰기 비용이 더 크다.
      t.references :product, null: false, foreign_key: true, index: false
      t.references :lot, null: true, foreign_key: true, index: false
      t.decimal :qty, precision: 14, scale: 3, null: false
      t.references :from_location, null: false, foreign_key: { to_table: :locations }, index: false
      t.references :to_location, null: false, foreign_key: { to_table: :locations }, index: false
      t.datetime :planned_at, null: false
      t.datetime :started_at
      t.datetime :finished_at
      t.references :stock_move, null: true, foreign_key: true, index: { unique: true }
      t.string :ref_type
      t.bigint :ref_id
      t.bigint :seq, null: false
      t.timestamps

      t.index %i[status planned_at]
      t.index %i[resource_id status]
      t.index :seq, unique: true

      t.check_constraint "kind IN ('unload','putaway','pick','feed','inspect','load')", name: "tasks_kind_check"
      t.check_constraint "status IN ('planned','started','done','cancelled')", name: "tasks_status_check"
      t.check_constraint "qty > 0", name: "tasks_qty_check"
      t.check_constraint "from_location_id <> to_location_id", name: "tasks_locations_differ_check"
      t.check_constraint "status NOT IN ('started','done') OR started_at IS NOT NULL", name: "tasks_started_at_check"
      t.check_constraint "status <> 'done' OR finished_at IS NOT NULL", name: "tasks_finished_at_check"
      t.check_constraint "stock_move_id IS NULL OR status = 'done'", name: "tasks_stock_move_done_check"
    end

    execute <<~SQL
      CREATE FUNCTION tasks_assign_seq() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        NEW.seq := nextval('tasks_seq');
        RETURN NEW;
      END;
      $$
    SQL
    execute <<~SQL
      CREATE TRIGGER tasks_assign_seq BEFORE INSERT OR UPDATE ON tasks
      FOR EACH ROW EXECUTE FUNCTION tasks_assign_seq()
    SQL
  end

  def down
    drop_table :tasks
    execute "DROP FUNCTION tasks_assign_seq()"
    execute "DROP SEQUENCE tasks_seq"
  end
end
