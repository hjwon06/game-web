# 원장. append-only: UPDATE/DELETE/TRUNCATE 는 트리거가 막는다(공장 stock_moves 와 같은 방식).
# updated_at 이 없다 — 수정이 없는 테이블이다.
class CreateLedgerEntries < ActiveRecord::Migration[8.1]
  def up
    create_table :ledger_entries do |t|
      t.references :settlement, null: false, foreign_key: true
      t.references :from_account, null: false, foreign_key: { to_table: :accounts }
      t.references :to_account, null: false, foreign_key: { to_table: :accounts }
      t.references :asset, null: false, foreign_key: true
      t.bigint :qty, null: false
      t.string :idem_key, null: false
      t.timestamptz :created_at, null: false, default: -> { "now()" }

      t.index :idem_key, unique: true, name: "ledger_entries_idem_key_uidx"
      t.check_constraint "qty > 0", name: "ledger_entries_qty_check"
      t.check_constraint "from_account_id <> to_account_id", name: "ledger_entries_accounts_differ_check"
    end

    execute <<~SQL
      CREATE FUNCTION ledger_entries_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'ledger_entries is append-only (% blocked)', TG_OP USING ERRCODE = 'restrict_violation';
      END;
      $$;
      CREATE TRIGGER ledger_entries_no_update_delete BEFORE UPDATE OR DELETE ON ledger_entries
        FOR EACH ROW EXECUTE FUNCTION ledger_entries_append_only();
      CREATE TRIGGER ledger_entries_no_truncate BEFORE TRUNCATE ON ledger_entries
        FOR EACH STATEMENT EXECUTE FUNCTION ledger_entries_append_only();
    SQL
  end

  def down
    drop_table :ledger_entries
    execute "DROP FUNCTION IF EXISTS ledger_entries_append_only()"
  end
end
