class CreateCommands < ActiveRecord::Migration[8.1]
  def change
    create_table :commands do |t|
      t.uuid :idempotency_key, null: false
      t.references :machine, null: false, foreign_key: true
      t.string :kind, null: false
      t.integer :base_version, null: false
      t.integer :result_status
      t.datetime :created_at, null: false

      t.index :idempotency_key, unique: true
      t.check_constraint "kind IN ('start','stop','break','repair')", name: "commands_kind_check"
    end
  end
end
