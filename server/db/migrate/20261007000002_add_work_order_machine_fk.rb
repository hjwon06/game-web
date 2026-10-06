# production_events 의 machine_id 와 work_order_id 가 다른 기계를 가리키지 못하게 복합 FK 로 묶는다.
class AddWorkOrderMachineFk < ActiveRecord::Migration[8.1]
  def change
    add_index :work_orders, [:id, :machine_id], unique: true, name: "index_work_orders_on_id_and_machine_id"
    add_foreign_key :production_events, :work_orders, column: [:work_order_id, :machine_id],
                                                      primary_key: [:id, :machine_id],
                                                      name: "fk_production_events_work_order_machine"
  end
end
