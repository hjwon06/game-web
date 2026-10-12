# 계좌. depository(예탁)는 개시 잔고의 출처라 positions 행을 갖지 않는다.
class CreateAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts do |t|
      t.string :code, null: false
      t.string :name, null: false
      t.string :kind, null: false

      t.index :code, unique: true, name: "accounts_code_uidx"
      t.check_constraint "kind IN ('investor','broker','clearing','depository')", name: "accounts_kind_check"
    end
  end
end
