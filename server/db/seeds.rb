# 반복 실행해도 중복 생성되지 않는다 (find_or_create_by!). 기계 id·이름은 data/factory.json 과 같다.
MACHINES = [
  { code: "M1", name: "절단기", state: "running", order: ["WO-1001", "브래킷 A", 300] },
  { code: "M2", name: "조립기", state: "stopped", order: ["WO-1002", "하우징 B", 180] },
  { code: "M3", name: "검사기", state: "broken", order: ["WO-1003", "플레이트 C", 120] },
  { code: "M4", name: "가공기", state: "running", order: ["WO-1004", "샤프트 D", 240] }
].freeze

MACHINES.each do |spec|
  machine = Machine.find_or_create_by!(code: spec[:code]) do |m|
    m.name = spec[:name]
    m.state = spec[:state]
  end

  code, product, target_qty = spec[:order]
  WorkOrder.find_or_create_by!(code: code) do |wo|
    wo.machine = machine
    wo.product = product
    wo.target_qty = target_qty
    wo.status = "active"
    wo.started_at = Time.current
  end
end
