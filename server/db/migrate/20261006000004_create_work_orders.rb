class CreateWorkOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :work_orders do |t|
      t.string :code, null: false
      t.references :machine, null: false, foreign_key: true, index: false
      t.string :product, null: false
      t.integer :target_qty, null: false
      t.integer :produced_qty, null: false, default: 0
      t.string :status, null: false, default: "queued"
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps

      t.index :code, unique: true
      t.index :machine_id, unique: true, where: "status = 'active'",
                           name: "index_work_orders_one_active_per_machine"
      t.check_constraint "target_qty > 0", name: "work_orders_target_qty_check"
      t.check_constraint "status IN ('queued','active','done')", name: "work_orders_status_check"
    end
  end
end
