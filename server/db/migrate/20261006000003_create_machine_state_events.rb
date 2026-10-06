class CreateMachineStateEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :machine_state_events do |t|
      t.references :machine, null: false, foreign_key: true, index: false
      t.references :command, null: true, foreign_key: true, index: false
      t.string :from_state, null: false
      t.string :to_state, null: false
      t.integer :version, null: false
      t.timestamptz :at, null: false

      t.index [:machine_id, :version], unique: true
    end
  end
end
