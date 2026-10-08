require "test_helper"

# /api/campus?include=ops (관제 카드 6묶음)와 /api/campus/search. 시각은 2026-10-09 12:00:00 UTC 로 얼려 진행률·ETA 를 정확히 비교한다.
class CampusOpsTest < ActionDispatch::IntegrationTest
  OPS_MAX_QUERIES = 18
  BASE_KEYS = %w[buildings last_move_id last_seq moves resources server_time sim_note tasks].freeze
  P = Simulation::Config::PALLET_QTY

  setup do
    @t = Time.utc(2026, 10, 9, 12, 0, 0)
    travel_to @t
    @raw = Product.create!(sku: "RAW-OPS", name: "캠퍼스원자재", uom: "ea", kind: "raw")
    @fg = Product.create!(sku: "FG-OPS", name: "캠퍼스완제품", uom: "ea", kind: "fg")
    @lot = Lot.create!(product: @fg, lot_no: "LOT-OPS")
    @supplier = Supplier.create!(code: "SUP-OPS", name: "캠퍼스공급사", lead_time_seconds: 120)
    @seq = 0
    sign_in_as create_user
  end

  def ops(params = {})
    get "/api/campus", params: { include: "ops" }.merge(params)
    assert_response :ok
    response.parsed_body["ops"]
  end

  def loc(code) = Location.find_by!(code: code)

  def iso(time) = time.utc.iso8601(3)

  def mv(type, from, to, qty, at, product: @raw, lot: nil, ref: nil)
    Inventory::Move.call(product: product, lot: lot, from: from, to: to, qty: qty, move_type: type, ref: ref,
                         idempotency_key: "ops-#{@seq += 1}", occurred_at: at)
  end

  def task!(kind:, status:, resource:, from:, to:, ref: nil, product: @raw, lot: nil, qty: P, started: nil, expected: nil, finished: nil, updated_at: nil)
    started ||= @t if %w[started done].include?(status)
    finished ||= started + 30.seconds if status == "done"
    attrs = { kind: kind, status: status, resource: Resource.find_by!(code: resource), product: product, lot: lot, qty: qty,
              from_location: loc(from), to_location: loc(to), planned_at: @t, started_at: started, finished_at: finished,
              expected_finish_at: expected, ref_type: ref&.class&.name, ref_id: ref&.id }
    attrs[:updated_at] = updated_at if updated_at
    Task.create!(**attrs)
  end

  def po!(no, status, pallets, expected: @t + 3.minutes)
    po = PurchaseOrder.create!(po_no: no, supplier: @supplier, status: status, ordered_at: @t - 1.minute, expected_at: expected,
                               arrived_at: (@t - 30.seconds if status == "arrived"))
    [po, po.lines.create!(product: @raw, qty_ordered: pallets * P)]
  end

  def so!(no, customer: "한빛정공", due: Date.new(2026, 10, 12), qty: 2 * P, status: "open")
    order = SalesOrder.create!(so_no: no, customer: customer, due_date: due, status: status)
    order.update_columns(created_at: @t - 5.hours)
    [order, SalesOrderLine.create!(sales_order: order, product: @fg, ordered_qty: qty)]
  end

  def count_queries
    count = 0
    counter = lambda do |*, payload|
      next if payload[:name] == "SCHEMA" || payload[:cached]
      next if payload[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)

      count += 1
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  # 트럭 5대: 상차 중 / 하차 중 / 하차 도크 대기 / 상차 도크 대기 / 오는 중
  def truck_scenario
    _po1, l1 = po!("PO-OPS-1", "arrived", 3)
    task!(kind: "unload", status: "done", resource: "DOCK-IN-01", from: "supplier", to: "receiving", ref: l1, started: @t - 2.minutes)
    task!(kind: "unload", status: "started", resource: "DOCK-IN-01", from: "supplier", to: "receiving", ref: l1, started: @t - 10.seconds, expected: @t + 20.seconds)
    task!(kind: "unload", status: "planned", resource: "DOCK-IN-01", from: "supplier", to: "receiving", ref: l1, expected: @t + 80.seconds)
    _po3, l3 = po!("PO-OPS-3", "arrived", 1)
    task!(kind: "unload", status: "planned", resource: "DOCK-IN-02", from: "supplier", to: "receiving", ref: l3, expected: @t + 50.seconds)
    po!("PO-OPS-2", "confirmed", 2, expected: @t + 3.minutes)

    _s1, sl1 = so!("SO-OPS-1")
    task!(kind: "load", status: "done", resource: "DOCK-OUT-01", from: "shipping", to: "customer", product: @fg, lot: @lot, ref: sl1, started: @t - 3.minutes)
    task!(kind: "load", status: "started", resource: "DOCK-OUT-01", from: "shipping", to: "customer", product: @fg, lot: @lot, ref: sl1,
          started: @t - 20.seconds, expected: @t + 40.seconds)
    _s2, sl2 = so!("SO-OPS-2", customer: "대성기계")
    task!(kind: "load", status: "planned", resource: "DOCK-OUT-02", from: "shipping", to: "customer", product: @fg, lot: @lot, ref: sl2, expected: @t + 100.seconds)
  end

  test "비로그인은 ops 도 401 이고 검색도 401 이다" do
    delete "/logout"
    get "/api/campus", params: { include: "ops" }
    assert_response :unauthorized
    get "/api/campus/search", params: { q: "PO" }
    assert_response :unauthorized
  end

  test "include 가 없으면 ops 키가 없고 있으면 ops 만 더해지며 나머지 응답은 그대로다" do
    get "/api/campus"
    plain = response.parsed_body
    get "/api/campus", params: { include: "bins" }
    assert_equal (BASE_KEYS + %w[bins]).sort, response.parsed_body.keys.sort
    get "/api/campus", params: { include: "ops" }
    with_ops = response.parsed_body

    assert_equal BASE_KEYS, plain.keys.sort
    assert_equal (BASE_KEYS + %w[ops]).sort, with_ops.keys.sort
    assert_equal plain.except("server_time"), with_ops.except("server_time", "ops")
  end

  test "ops 는 여섯 묶음 키를 갖고 비어 있으면 0 · nil · 빈 배열이다" do
    body = ops

    assert_equal %w[docks forklifts kpi shipment sites trucks], body.keys.sort
    assert_equal %w[on_time_rate pallets_delta_1h pallets_on_hand trucks_in trucks_on_site trucks_out], body["kpi"].keys.sort
    assert_equal [0, 0, 0, 0, 0], body["kpi"].values_at("pallets_on_hand", "pallets_delta_1h", "trucks_on_site", "trucks_in", "trucks_out")
    assert_nil body["kpi"]["on_time_rate"], "표본이 없으면 null"
    assert_equal [], body["trucks"]
    assert_equal %w[FORK-01 FORK-02], body["forklifts"].map { |f| f["code"] }
    assert_equal [nil, nil, 0], body["forklifts"].first.values_at("task", "progress", "planned_count")
    assert_equal %w[DOCK-IN-01 DOCK-IN-02 DOCK-OUT-01 DOCK-OUT-02], body["docks"].map { |d| d["code"] }
    assert body["docks"].none? { |d| d["occupied"] }
    assert_nil body["shipment"]
    assert_equal %w[mat prod qc ship], body["sites"].keys.sort
    body["sites"].each_value { |s| assert_equal({ "items" => [], "forklift_rate" => 0 }, s) }
  end

  test "kpi 팔레트 수는 칸·입고대·출하대만 세고 1시간 전 원장과 비교한다 (구역 안 이동은 제외)" do
    mv("receive", "supplier", "receiving", 1000, @t - 2.hours)  # 1시간 밖
    mv("receive", "supplier", "receiving", 500, @t - 20.minutes)
    mv("receive", "supplier", "receiving", 500, @t - 10.minutes)
    mv("putaway", "receiving", "RAW-A-01-01", 500, @t - 5.minutes) # 구역 안 이동: 합이 안 변한다
    mv("feed", "RAW-A-01-01", "line_side", 500, @t - 3.minutes)    # 라인 공급대로 나감: 팔레트 수에서 빠진다

    kpi = ops["kpi"]
    # 현재: 입고대 1500 (라인 공급대 500 은 세지 않는다) = 3팔레트. 1시간 전: 1500 - (+1000 - 500) = 1000 = 2팔레트.
    assert_equal 3, kpi["pallets_on_hand"]
    assert_equal 1, kpi["pallets_delta_1h"]
    assert_equal 500, Quant.where(location: loc("line_side")).sum(:qty), "라인 공급대에 500 이 실제로 있는데도 세지 않았다"
  end

  test "트럭 목록: 상태 · 도크 · 하차 진행 n/총 · ETA 와 정렬(작업 중 → 도크 대기 → 오는 중)" do
    truck_scenario

    body = ops
    trucks = body["trucks"]
    expected = [
      { "type" => "out", "no" => "SO-OPS-1", "party" => "한빛정공", "dock" => "DOCK-OUT-01", "status" => "loading", "done" => 1, "total" => 2, "eta" => iso(@t + 40.seconds) },
      { "type" => "in", "no" => "PO-OPS-1", "party" => "캠퍼스공급사", "dock" => "DOCK-IN-01", "status" => "unloading", "done" => 1, "total" => 3, "eta" => iso(@t + 80.seconds) },
      { "type" => "in", "no" => "PO-OPS-3", "party" => "캠퍼스공급사", "dock" => "DOCK-IN-02", "status" => "docking", "done" => 0, "total" => 1, "eta" => iso(@t + 50.seconds) },
      { "type" => "out", "no" => "SO-OPS-2", "party" => "대성기계", "dock" => "DOCK-OUT-02", "status" => "docking", "done" => 0, "total" => 1, "eta" => iso(@t + 100.seconds) },
      { "type" => "in", "no" => "PO-OPS-2", "party" => "캠퍼스공급사", "dock" => nil, "status" => "en_route", "done" => 0, "total" => 2, "eta" => iso(@t + 3.minutes) }
    ]
    assert_equal expected, trucks
    assert_equal({ "trucks_on_site" => 4, "trucks_in" => 2, "trucks_out" => 2 }, body["kpi"].slice("trucks_on_site", "trucks_in", "trucks_out"),
                 "오는 중(en_route)은 현장 트럭이 아니다")
  end

  test "트럭 목록은 최대 8건이다" do
    10.times { |i| po!("PO-OPS-E#{i}", "confirmed", 1, expected: @t + (i + 1).minutes) }
    truck_scenario

    trucks = ops["trucks"]
    assert_equal 8, trucks.size
    assert_equal %w[loading unloading docking docking], trucks.first(4).map { |t| t["status"] }
    assert trucks.drop(4).all? { |t| t["status"] == "en_route" }
    assert_equal 4, ops["kpi"]["trucks_on_site"], "목록이 잘려도 현장 트럭 수는 전체다"
  end

  test "도크: 열린 작업이 있으면 점유이고 현재 트럭은 진행 중(started) 작업의 번호다" do
    truck_scenario

    docks = ops["docks"].index_by { |d| d["code"] }
    assert_equal({ "code" => "DOCK-IN-01", "kind" => "dock_in", "occupied" => true, "truck" => "PO-OPS-1" }, docks["DOCK-IN-01"])
    assert_equal ["PO-OPS-3", true], docks["DOCK-IN-02"].values_at("truck", "occupied")
    assert_equal ["SO-OPS-1", "dock_out"], docks["DOCK-OUT-01"].values_at("truck", "kind")
    assert_equal ["SO-OPS-2", true], docks["DOCK-OUT-02"].values_at("truck", "occupied")
    # 끝난 작업만 남은 도크는 비어 있다
    Task.where(status: %w[planned started]).update_all(status: "cancelled")
    assert ops["docks"].none? { |d| d["occupied"] }
    assert ops["docks"].all? { |d| d["truck"].nil? }
  end

  test "지게차: 진행률은 시작~예상완료 대비 지금이고 대기 건수와 작업이 없으면 nil 이다" do
    task!(kind: "putaway", status: "started", resource: "FORK-01", from: "receiving", to: "RAW-A-01-01", started: @t - 30.seconds, expected: @t + 30.seconds)
    2.times { task!(kind: "putaway", status: "planned", resource: "FORK-01", from: "receiving", to: "RAW-A-01-02", expected: @t + 60.seconds) }
    task!(kind: "pick", status: "started", resource: "FORK-02", from: "FG-A-01-01", to: "shipping", product: @fg, lot: @lot, qty: 300,
          started: @t - 120.seconds, expected: @t - 60.seconds) # 예상 완료가 지났다: 100 에서 멈춘다

    forks = ops["forklifts"]
    assert_equal({ "code" => "FORK-01", "progress" => 50, "planned_count" => 2,
                   "task" => { "kind" => "putaway", "product" => "캠퍼스원자재", "qty" => 500, "from_code" => "receiving", "to_code" => "RAW-A-01-01" } },
                 forks[0])
    assert_equal({ "code" => "FORK-02", "progress" => 100, "planned_count" => 0,
                   "task" => { "kind" => "pick", "product" => "캠퍼스완제품", "qty" => 300, "from_code" => "FG-A-01-01", "to_code" => "shipping" } },
                 forks[1])

    Task.where(status: "started").update_all(status: "done", finished_at: @t)
    idle = ops["forklifts"].first
    assert_equal [nil, nil, 2], idle.values_at("task", "progress", "planned_count")
  end

  test "수주 추적: 단계 시각(받음 · 첫 pick · 전 pick 완료 · 상차 시작 · 출하)과 ?so= 지정" do
    order, line = so!("SO-OPS-A", qty: 2 * P)
    t0 = @t - 5.hours
    task!(kind: "pick", status: "done", resource: "FORK-01", from: "FG-A-01-01", to: "shipping", product: @fg, lot: @lot, ref: line, started: t0 + 30.seconds, finished: t0 + 1.minute, updated_at: @t - 4.hours)
    task!(kind: "pick", status: "done", resource: "FORK-01", from: "FG-A-01-02", to: "shipping", product: @fg, lot: @lot, ref: line, started: t0 + 90.seconds, finished: t0 + 2.minutes, updated_at: @t - 4.hours)
    task!(kind: "load", status: "started", resource: "DOCK-OUT-01", from: "shipping", to: "customer", product: @fg, lot: @lot, ref: line, qty: 2 * P, started: t0 + 3.minutes, updated_at: @t - 4.hours)
    Quant.create!(product: @fg, lot: @lot, location: loc("shipping"), qty: 2 * P)
    mv("ship", "shipping", "customer", P, t0 + 4.minutes, product: @fg, lot: @lot, ref: line)
    order.update!(status: "partial")

    stages = ops["shipment"]
    assert_equal %w[SO-OPS-A 한빛정공], stages.values_at("so_no", "customer")
    assert_equal %w[received picked staged loaded shipped], stages["stages"].map { |s| s["key"] }
    assert_equal [iso(@t - 5.hours), iso(t0 + 1.minute), iso(t0 + 2.minutes), iso(t0 + 3.minutes), iso(t0 + 4.minutes)], stages["stages"].map { |s| s["at"] }

    mv("ship", "shipping", "customer", P, t0 + 6.minutes, product: @fg, lot: @lot, ref: line)
    order.update!(status: "done")
    assert_equal iso(t0 + 6.minutes), ops(so: "SO-OPS-A")["shipment"]["stages"].last["at"], "done 수주의 출하 시각은 마지막 출하다"

    # 열린 수주 중 가장 최근에 움직인 것이 기본 대상이고, pick 이 모자란 수주는 staged 가 비어 있다
    _b, line_b = so!("SO-OPS-B", customer: "서진산업")
    task!(kind: "pick", status: "done", resource: "FORK-01", from: "FG-A-01-03", to: "shipping", product: @fg, lot: @lot, ref: line_b, qty: P, finished: @t - 1.minute, updated_at: @t - 1.minute)
    _c, line_c = so!("SO-OPS-C")
    task!(kind: "pick", status: "planned", resource: "FORK-01", from: "FG-A-01-04", to: "shipping", product: @fg, lot: @lot, ref: line_c, qty: P, updated_at: @t - 3.hours)

    default = ops["shipment"]
    assert_equal "SO-OPS-B", default["so_no"], "done 인 A 는 후보가 아니고, B 의 작업이 C 보다 최근이다"
    assert_equal [true, true, false, false, false], default["stages"].map { |s| !s["at"].nil? }
    assert_nil ops(so: "SO-NOPE")["shipment"]
    assert_equal "SO-OPS-C", ops(so: "SO-OPS-C")["shipment"]["so_no"]
  end

  test "on_time_rate: 최근 7일 done 수주 중 납기일(당일 포함) 안에 마지막 출하가 끝난 비율, 소수 1자리" do
    Quant.create!(product: @fg, lot: @lot, location: loc("shipping"), qty: 1000)
    {
      ["SO-ONT-A", Date.new(2026, 10, 9)] => Time.utc(2026, 10, 9, 8, 0, 0),   # 납기 당일: 정시
      ["SO-ONT-B", Date.new(2026, 10, 7)] => Time.utc(2026, 10, 8, 10, 0, 0),  # 하루 늦음
      ["SO-ONT-C", Date.new(2026, 10, 12)] => Time.utc(2026, 10, 8, 10, 0, 0), # 일찍
      ["SO-ONT-OLD", Date.new(2026, 10, 1)] => Time.utc(2026, 9, 25, 10, 0, 0) # 7일 밖: 표본 아님
    }.each do |(no, due), shipped_at|
      order, line = so!(no, due: due, qty: 10)
      mv("ship", "shipping", "customer", 10, shipped_at, product: @fg, lot: @lot, ref: line)
      order.update!(status: "done")
    end
    so!("SO-ONT-OPEN", due: Date.new(2026, 10, 1), qty: 10) # 열린 수주는 표본이 아니다

    assert_equal 66.7, ops["kpi"]["on_time_rate"]
  end

  test "건물 재고 상위 5와 재주문점 미만(low) · 가상 위치 제외 · 건물 지게차 작업률" do
    machine = Machine.create!(code: "MOPS", name: "캠퍼스기계", state: "running")
    WorkOrder.create!(code: "WO-OPS", machine: machine, item: @fg, product: "캠퍼스완제품", target_qty: 100, status: "active")
    BomLine.create!(product: @fg, component: @raw, qty_per: 1)
    rule = ReorderRule.create!(product: @raw, min_minutes: 1000, max_minutes: 2000)
    Quant.create!(product: @raw, location: loc("RAW-A-01-01"), qty: 700)
    Quant.create!(product: @raw, location: loc("receiving"), qty: 100)
    Quant.create!(product: @raw, location: loc("line_side"), qty: 50)
    Quant.create!(product: @raw, location: loc("production"), qty: 25) # 가상 위치: 건물 재고가 아니다
    Quant.create!(product: @fg, lot: @lot, location: loc("FG-A-01-01"), qty: 300)
    Quant.create!(product: @fg, lot: @lot, location: loc("qc"), qty: 40)
    task!(kind: "putaway", status: "started", resource: "FORK-01", from: "receiving", to: "RAW-A-01-01", started: @t, expected: @t + 30.seconds)
    task!(kind: "pick", status: "started", resource: "FORK-02", from: "FG-A-01-01", to: "shipping", product: @fg, lot: @lot, started: @t, expected: @t + 30.seconds)

    sites = ops["sites"]
    assert_equal [{ "product" => "캠퍼스원자재", "qty" => 800, "status" => "low" }], sites["mat"]["items"]
    assert_equal [{ "product" => "캠퍼스원자재", "qty" => 50, "status" => "low" }], sites["prod"]["items"]
    assert_equal [{ "product" => "캠퍼스완제품", "qty" => 300, "status" => "in_stock" }], sites["ship"]["items"], "재주문점 없는 품목은 in_stock"
    assert_equal [{ "product" => "캠퍼스완제품", "qty" => 40, "status" => "in_stock" }], sites["qc"]["items"]
    assert_equal({ "mat" => 50, "ship" => 50, "qc" => 0, "prod" => 0 }, sites.transform_values { |s| s["forklift_rate"] })

    rule.update!(min_minutes: 1, max_minutes: 2)
    assert_equal "in_stock", ops["sites"]["mat"]["items"].first["status"], "보유 분수가 min 이상이면 low 가 아니다"
  end

  test "건물 재고는 품목별 수량 내림차순 상위 5개만 준다" do
    (1..7).each do |n|
      product = Product.create!(sku: "RAW-TOP#{n}", name: "상위#{n}", uom: "ea", kind: "raw")
      Quant.create!(product: product, location: loc("receiving"), qty: n * 10)
    end

    items = ops["sites"]["mat"]["items"]
    assert_equal %w[상위7 상위6 상위5 상위4 상위3], items.map { |i| i["product"] }
    assert_equal [70, 60, 50, 40, 30], items.map { |i| i["qty"] }
  end

  test "ops 쿼리 수는 상한 이하이고 작업·발주·수주 건수와 무관하다" do
    truck_scenario
    plain = count_queries { get "/api/campus" }
    small = count_queries { get "/api/campus", params: { include: "ops" } }
    assert_response :ok

    30.times { |i| task!(kind: "putaway", status: "planned", resource: "FORK-01", from: "receiving", to: "RAW-A-01-01", expected: @t + i.seconds) }
    6.times { |i| po!("PO-OPS-X#{i}", "confirmed", 1) }
    4.times { |i| _o, l = so!("SO-OPS-X#{i}"); task!(kind: "pick", status: "done", resource: "FORK-02", from: "FG-A-01-01", to: "shipping", product: @fg, lot: @lot, ref: l) }
    large = count_queries { get "/api/campus", params: { include: "ops", so: "SO-OPS-1" } }

    assert_operator small - plain, :<=, OPS_MAX_QUERIES, "ops 가 더한 쿼리 #{small - plain}개"
    assert_equal small - plain, large - plain, "건수가 늘어도 ops 쿼리 수는 그대로"
  end

  # --- 검색 ---------------------------------------------------------------------------------

  def search(q)
    get "/api/campus/search", params: { q: q }
    assert_response :ok
    response.parsed_body["results"]
  end

  test "검색: 유형별 한 건씩 {type, code, label, building}" do
    po!("PO-QX1", "confirmed", 1)
    so!("SO-QX1", customer: "큐엑스고객")
    Product.create!(sku: "RAW-QX", name: "큐엑스볼트", uom: "ea", kind: "raw")

    assert_equal [{ "type" => "po", "code" => "PO-QX1", "label" => "캠퍼스공급사", "building" => "office" }], search("PO-QX")
    assert_equal [{ "type" => "so", "code" => "SO-QX1", "label" => "큐엑스고객", "building" => "office" }], search("so-qx")
    assert_equal [{ "type" => "resource", "code" => "FORK-02", "label" => "지게차", "building" => "material" }], search("fork-02")
    assert_equal [{ "type" => "resource", "code" => "DOCK-OUT-01", "label" => "출하 도크", "building" => "shipping_dock" }], search("DOCK-OUT-01")
    assert_equal [{ "type" => "bin", "code" => "RAW-A-03-04", "label" => loc("RAW-A-03-04").name, "building" => "material" }], search("RAW-A-03-04")
    assert_equal [{ "type" => "bin", "code" => "FG-A-02-05", "label" => loc("FG-A-02-05").name, "building" => "shipping_wh" }], search("FG-A-02-05")
    assert_equal [{ "type" => "product", "code" => "RAW-QX", "label" => "큐엑스볼트", "building" => "material" }], search("엑스볼")
  end

  test "검색: 유형 순서(발주 → 수주 → 자원 → 칸 → 품목)로 최대 8건이고 작업자 자원은 빠진다" do
    po!("PO-ZZ1", "confirmed", 1)
    so!("SO-ZZ1")
    Product.create!(sku: "FG-ZZ", name: "ZZ제품", uom: "ea", kind: "fg")

    assert_equal %w[po so product], search("zz").map { |r| r["type"] }
    assert_equal "shipping_wh", search("ZZ제품").first["building"]
    assert_equal [], search("WORKER"), "작업자는 검색 대상이 아니다"

    10.times { |i| po!("PO-LIM-#{i}", "confirmed", 1) }
    assert_equal 8, search("PO-LIM").size
    assert_equal 8, search("-").size, "첫 유형이 8건을 채우면 뒤 유형은 8건을 넘기지 않는다"
  end

  test "검색: 빈 검색어는 빈 배열이고 % · _ 는 와일드카드가 아니다" do
    po!("PO-WILD", "confirmed", 1)

    assert_equal [], search("")
    assert_equal [], search("   ")
    assert_equal [], search("%")
    assert_equal [], search("PO_WILD")
    assert_equal "PO-WILD", search("o-w").first["code"]
  end
end
