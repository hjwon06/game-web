class AddCheckConstraints < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :machines, "version >= 0", name: "machines_version_check"
    add_check_constraint :commands, "base_version >= 0", name: "commands_base_version_check"
    add_check_constraint :work_orders, "produced_qty >= 0", name: "work_orders_produced_qty_check"
    add_check_constraint :production_events, "machine_version >= 0", name: "production_events_machine_version_check"
  end
end
