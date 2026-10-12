# 결제일 1건 = 1행. executions·ledger_entries 가 참조하므로 그보다 먼저 만든다.
class CreateSettlements < ActiveRecord::Migration[8.1]
  def change
    create_table :settlements do |t|
      t.date :settle_date, null: false
      t.string :status, null: false
      t.timestamptz :settled_at

      t.index :settle_date, unique: true, name: "settlements_settle_date_uidx"
      t.check_constraint "status IN ('pending','settled')", name: "settlements_status_check"
    end
  end
end
