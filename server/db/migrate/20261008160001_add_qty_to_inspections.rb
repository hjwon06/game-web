class AddQtyToInspections < ActiveRecord::Migration[8.1]
  # 검사 1행의 수량. 미검사량을 지워지는 tasks 가 아니라 이 원장으로 센다. 기존 행은 연결된 이동(stock_moves)의 수량으로 채운다.
  def up
    add_column :inspections, :qty, :decimal, precision: 14, scale: 3, null: false, default: 0
    execute "UPDATE inspections SET qty = m.qty FROM stock_moves m WHERE m.id = inspections.stock_move_id"
    add_check_constraint :inspections, "qty >= 0", name: "inspections_qty_check"
  end

  def down
    remove_check_constraint :inspections, name: "inspections_qty_check"
    remove_column :inspections, :qty
  end
end
