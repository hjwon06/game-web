class CreateMachines < ActiveRecord::Migration[8.1]
  def change
    create_table :machines do |t|
      t.string :code, null: false
      t.string :name, null: false
      t.string :state, null: false, default: "stopped"
      t.integer :version, null: false, default: 0
      t.timestamps

      t.index :code, unique: true
      t.check_constraint "state IN ('running','stopped','broken')", name: "machines_state_check"
    end
  end
end
