# 반복 실행해도 중복 생성되지 않는다 (find_or_create_by!). M1~M4 의 id·이름은 data/factory.json 과 같다.
# 각 항목: [code, 이름, 초기 state, active 지시, queued 지시]. 지시는 [code, 제품, 목표 수량].
MACHINES = [
  ["M1", "절단기", "running", ["WO-1001", "브래킷 A", 300], ["WO-2001", "브래킷 E", 200]],
  ["M2", "조립기", "stopped", ["WO-1002", "하우징 B", 180], ["WO-2002", "하우징 F", 150]],
  ["M3", "검사기", "broken", ["WO-1003", "플레이트 C", 120], ["WO-2003", "플레이트 G", 140]],
  ["M4", "가공기", "running", ["WO-1004", "샤프트 D", 240], ["WO-2004", "샤프트 H", 220]],
  ["M5", "절단기 2", "running", ["WO-1005", "브래킷 I", 260], ["WO-2005", "브래킷 J", 180]],
  ["M6", "가공기 2", "running", ["WO-1006", "샤프트 K", 200], ["WO-2006", "샤프트 L", 240]],
  ["M7", "조립기 2", "running", ["WO-1007", "하우징 M", 160], ["WO-2007", "하우징 N", 280]],
  ["M8", "검사기 2", "running", ["WO-1008", "플레이트 O", 220], ["WO-2008", "플레이트 P", 130]],
  ["M9", "도장기 1", "running", ["WO-1009", "패널 Q", 250], ["WO-2009", "패널 R", 190]],
  ["M10", "도장기 2", "running", ["WO-1010", "패널 S", 300], ["WO-2010", "패널 T", 170]],
  ["M11", "포장기 1", "stopped", ["WO-1011", "박스 U", 140], ["WO-2011", "박스 V", 210]],
  ["M12", "포장기 2", "stopped", ["WO-1012", "박스 W", 270], ["WO-2012", "박스 X", 120]]
].freeze

Location.ensure_defaults!

def seed_order(machine, (code, product, target_qty), status)
  WorkOrder.find_or_create_by!(code: code) do |wo|
    wo.machine = machine
    wo.product = product
    wo.target_qty = target_qty
    wo.status = status
    wo.started_at = Time.current if status == "active"
  end
end

MACHINES.each do |code, name, state, active, queued|
  machine = Machine.find_or_create_by!(code: code) do |m|
    m.name = name
    m.state = state
  end
  seed_order(machine, active, "active")
  seed_order(machine, queued, "queued")
end

# 재고 시드는 위 작업지시 품목(브래킷 A 등)을 재사용하므로 반드시 뒤에 둔다. 모든 변동은 Inventory::Move 를 거친다.
require "rake"
Rails.application.load_tasks unless Rake::Task.task_defined?("inventory:seed")
Rake::Task["inventory:seed"].reenable
Rake::Task["inventory:seed"].invoke

# 적치 규칙: 자재별 전용 랙 1개씩(강판 RAW-A-01, 볼트 RAW-A-02, 패킹 RAW-A-03), 공용 RAW-A-04 는 priority 90, 완제품은 FG 랙 4개 공용.
# 자재 품목이 있어야 전용 규칙이 만들어지므로 재고 시드 뒤에 둔다. 이미 있는 규칙(바꿔 둔 priority 포함)은 건드리지 않는다.
PutawayRule.ensure_defaults!

# 공급사: 강판 1곳(리드타임 120초), 볼트·패킹 1곳(180초). 자재 품목이 있어야 연결되므로 역시 재고 시드 뒤에 둔다. 이미 있는 값은 건드리지 않는다.
Supplier.ensure_defaults!
