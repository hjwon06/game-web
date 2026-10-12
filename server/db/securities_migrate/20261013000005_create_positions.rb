# 결제분 잔고만 둔다(미결제 체결은 positions 에 없다). 예탁 계좌는 행이 없다.
class CreatePositions < ActiveRecord::Migration[8.1]
  def change
    create_table :positions do |t|
      t.references :account, null: false, foreign_key: true, index: false
      t.references :asset, null: false, foreign_key: true
      t.bigint :qty, null: false

      t.index [:account_id, :asset_id], unique: true, name: "positions_account_asset_uidx"
      t.check_constraint "qty >= 0", name: "positions_qty_check"
    end
  end
end
