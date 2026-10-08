# 이동 원장. append-only: UPDATE/DELETE/TRUNCATE 는 트리거가 막는다.
# 주의: 트리거는 schema.rb 로 덤프되지 않는다 (schema.rb 끝의 execute 블록 참조).
class CreateStockMoves < ActiveRecord::Migration[8.1]
  def up
    create_table :stock_moves do |t|
      t.references :product, null: false, foreign_key: true, index: false
      t.references :lot, foreign_key: true
      t.references :from_location, null: false, foreign_key: { to_table: :locations }
      t.references :to_location, null: false, foreign_key: { to_table: :locations }
      t.decimal :qty, precision: 14, scale: 3, null: false
      t.string :move_type, null: false
      t.string :ref_type
      t.bigint :ref_id
      t.string :idempotency_key, null: false
      t.timestamptz :occurred_at, null: false, default: -> { "now()" }
      t.timestamptz :created_at, null: false, default: -> { "now()" }

      t.index [:product_id, :occurred_at]
      t.index [:ref_type, :ref_id]
      t.index :idempotency_key, unique: true
      t.check_constraint "qty > 0", name: "stock_moves_qty_check"
      t.check_constraint "from_location_id <> to_location_id", name: "stock_moves_locations_differ_check"
      t.check_constraint "move_type IN ('receive','putaway','issue','produce','qc_pass','qc_fail','ship')",
                         name: "stock_moves_move_type_check"
    end

    execute <<~SQL
      CREATE FUNCTION stock_moves_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'stock_moves is append-only (% blocked)', TG_OP USING ERRCODE = 'restrict_violation';
      END;
      $$;
      CREATE TRIGGER stock_moves_no_update_delete BEFORE UPDATE OR DELETE ON stock_moves
        FOR EACH ROW EXECUTE FUNCTION stock_moves_append_only();
      CREATE TRIGGER stock_moves_no_truncate BEFORE TRUNCATE ON stock_moves
        FOR EACH STATEMENT EXECUTE FUNCTION stock_moves_append_only();
    SQL
  end

  def down
    drop_table :stock_moves
    execute "DROP FUNCTION IF EXISTS stock_moves_append_only()"
  end
end
