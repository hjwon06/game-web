require "test_helper"

class CampusControllerTest < ActionDispatch::IntegrationTest
  MAX_QUERIES = 20

  setup do
    @baseline_id = StockMove.maximum(:id) || 0
    @raw = Product.create!(sku: "RAW-CMP", name: "캠퍼스원자재", uom: "ea", kind: "raw")
    @fg = Product.create!(sku: "FG-CMP", name: "캠퍼스완제품", uom: "ea", kind: "fg")
    @lot = Lot.create!(product: @fg, lot_no: "LOT-CMP")
    @machine = Machine.create!(code: "MCMP", name: "캠퍼스기계")
    @wo = WorkOrder.create!(code: "WO-CMP", machine: @machine, item: @fg, product: "캠퍼스완제품", target_qty: 100)
    @order = SalesOrder.create!(so_no: "SO-CMP", customer: "시드고객", due_date: Date.new(2026, 11, 1))
    @line = SalesOrderLine.create!(sales_order: @order, product: @fg, ordered_qty: 20)
    @seq = 0
  end

  def move(type, product: @raw, lot: nil, qty: 1, ref: nil)
    from, to = Inventory::Move::ALLOWED_PATHS.fetch(type)
    Inventory::Move.call(product: product, lot: lot, from: from, to: to, qty: qty, move_type: type, ref: ref,
                         idempotency_key: "cmp-#{type}-#{@seq += 1}")
  end

  # 생산 10 -> 검사 합격 8 / 불합격 2 -> pick 5 (fg_store → shipping) -> 출하 5 (shipping → customer)
  def run_flow
    move("produce", product: @fg, lot: @lot, qty: 10, ref: @wo)
    Inventory::Inspect.call(lot: @lot, work_order: @wo, pass_qty: 8, fail_qty: 2, idempotency_key: "cmp-insp")
    move("pick", product: @fg, lot: @lot, qty: 5)
    Inventory::Ship.call(sales_order_line: @line, lot: @lot, qty: 5, idempotency_key: "cmp-ship")
  end

  def make_task(kind: "putaway", status: "planned", resource: nil, from: "receiving", to: "raw_store", planned_at: Time.current, **attrs)
    started = %w[started done].include?(status) ? planned_at : nil
    finished = status == "done" ? planned_at + 30.seconds : nil
    Task.create!(kind: kind, status: status, resource: resource, product: @raw, qty: 1,
                 from_location: Location.find_by!(code: from), to_location: Location.find_by!(code: to),
                 planned_at: planned_at, started_at: started, finished_at: finished,
                 expected_finish_at: planned_at + 30.seconds, **attrs)
  end

  def tasks_of(params = {})
    get "/api/campus", params: params
    assert_response :ok
    response.parsed_body
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

  test "비로그인은 401 JSON 이다" do
    get "/api/campus"

    assert_response :unauthorized
    assert_equal({ "error" => "login_required" }, response.parsed_body)
  end

  test "로그인하면 200 이고 P1~P4 키가 있다" do
    sign_in_as create_user
    get "/api/campus"

    assert_response :ok
    body = response.parsed_body
    assert_equal %w[buildings last_move_id last_seq moves resources server_time sim_note tasks], body.keys.sort
    assert_equal %w[hall material office qc shipping], body["buildings"].keys.sort
    assert_equal %w[open_pos orders recent recent_pos], body["buildings"]["office"].keys.sort
    assert_equal %w[raw_store received_trucks_10m receiving_qty], body["buildings"]["material"].keys.sort
    assert_equal %w[broken running stopped], body["buildings"]["hall"].keys.sort
    assert_equal %w[defect_ratio_60m fail_60m pass_60m qty], body["buildings"]["qc"].keys.sort
    assert_equal %w[fg_store partial_orders shipped_60m], body["buildings"]["shipping"].keys.sort
    assert_kind_of String, body["sim_note"]
    assert_operator body["moves"].size, :<=, 20
  end

  test "after_id 이후만 오름차순으로 최대 50건 오고 last_move_id 로 이어서 받는다" do
    sign_in_as create_user
    60.times { move("receive") }
    first = StockMove.where("id > ?", @baseline_id).order(:id).first.id

    get "/api/campus", params: { after_id: first - 1 }
    ids = response.parsed_body["moves"].map { |m| m["id"] }
    assert_equal 50, ids.size
    assert_equal ids.sort, ids
    assert_equal first, ids.first
    assert_equal ids.last, response.parsed_body["last_move_id"]

    get "/api/campus", params: { after_id: ids.last }
    rest = response.parsed_body["moves"].map { |m| m["id"] }
    assert_equal StockMove.where("id > ?", ids.last).order(:id).limit(50).pluck(:id), rest
    assert_equal 10, rest.size

    get "/api/campus", params: { after_id: rest.last }
    assert_equal [], response.parsed_body["moves"]
    assert_equal rest.last, response.parsed_body["last_move_id"], "새 이동이 없으면 after_id 를 그대로 돌려준다"
  end

  test "after_id 가 없으면 최근 20건을 id 오름차순으로 준다" do
    sign_in_as create_user
    25.times { move("receive") }

    get "/api/campus"
    ids = response.parsed_body["moves"].map { |m| m["id"] }
    assert_equal StockMove.order(id: :desc).limit(20).pluck(:id).reverse, ids
    assert_equal StockMove.maximum(:id), response.parsed_body["last_move_id"]
  end

  test "잘못된 after_id 는 400 이다" do
    sign_in_as create_user
    get "/api/campus", params: { after_id: "abc" }

    assert_response :bad_request
  end

  test "이동 항목에 필드와 WO 코드 · 수주번호 ref 가 실린다" do
    sign_in_as create_user
    run_flow

    get "/api/campus", params: { after_id: @baseline_id }
    moves = response.parsed_body["moves"]
    produce = moves.find { |m| m["type"] == "produce" }
    ship = moves.find { |m| m["type"] == "ship" }
    pass = moves.find { |m| m["type"] == "qc_pass" }

    assert_equal %w[at from_code id lot qty ref to_code type product].sort, produce.keys.sort
    assert_equal ["production", "qc", "WO-CMP", "LOT-CMP", 10, "캠퍼스완제품"],
                 produce.values_at("from_code", "to_code", "ref", "lot", "qty", "product")
    assert_equal ["shipping", "customer", "SO-CMP", 5], ship.values_at("from_code", "to_code", "ref", "qty")
    assert_equal "WO-CMP", pass["ref"]
    assert_nil moves.find { |m| m["type"] == "receive" }
  end

  test "건물 숫자가 DB 와 맞는다 (수주 상태, 불합격률, 출하, 입고)" do
    sign_in_as create_user
    run_flow
    2.times { move("receive", qty: 7) } # 팔레트 단위 입고 이동 2건. 트럭 수는 이동이 아니라 발주(PO) 도착으로 센다.
    supplier = Supplier.create!(code: "SUP-CMP", name: "캠퍼스공급사", lead_time_seconds: 120)
    now = Time.current
    [["PO-CMP-1", "done", now - 5.minutes], ["PO-CMP-2", "arrived", now - 1.minute], ["PO-CMP-3", "done", now - 9.minutes],
     ["PO-CMP-4", "done", now - 30.minutes], ["PO-CMP-5", "confirmed", nil]].each do |po_no, status, arrived_at|
      po = PurchaseOrder.create!(po_no: po_no, supplier: supplier, status: status, ordered_at: now - 1.hour,
                                 expected_at: now - 1.minute, arrived_at: arrived_at)
      po.lines.create!(product: @raw, qty_ordered: 10)
    end

    get "/api/campus"
    b = response.parsed_body["buildings"]

    expected_orders = SalesOrder.group(:status).count
    assert_equal SalesOrder::STATUSES.to_h { |s| [s, expected_orders.fetch(s, 0)] }, b["office"]["orders"]
    assert_equal "partial", @order.reload.status
    assert_includes b["office"]["recent"].map { |o| o["so_no"] }, "SO-CMP"
    assert_operator b["office"]["recent"].size, :<=, 3

    since = 60.minutes.ago
    pass = StockMove.where(move_type: "qc_pass", occurred_at: since..).sum(:qty)
    fail = StockMove.where(move_type: "qc_fail", occurred_at: since..).sum(:qty)
    assert_in_delta fail.to_f / (pass + fail), b["qc"]["defect_ratio_60m"], 0.0001
    assert_equal [pass.to_i, fail.to_i], [b["qc"]["pass_60m"], b["qc"]["fail_60m"]]
    assert_equal Quant.where(location: Location.find_by!(code: "qc")).sum(:qty).to_i, b["qc"]["qty"]

    assert_equal StockMove.where(move_type: "ship", occurred_at: since..).sum(:qty).to_i, b["shipping"]["shipped_60m"]
    assert_equal expected_orders.fetch("partial", 0), b["shipping"]["partial_orders"]
    assert_operator b["shipping"]["fg_store"].size, :<=, 5
    assert_equal 3, b["shipping"]["fg_store"].find { |r| r["sku"] == "FG-CMP" }["qty"]

    assert_equal PurchaseOrder.where(arrived_at: 10.minutes.ago..).count, b["material"]["received_trucks_10m"]
    assert_equal 3, b["material"]["received_trucks_10m"], "최근 10분 arrived_at 인 발주만(done 포함). 30분 전 도착분과 아직 안 온 발주는 뺀다"
    assert_not_equal StockMove.where(move_type: "receive").count, b["material"]["received_trucks_10m"], "receive 이동 건수가 아니다"
    assert_equal PurchaseOrder.where(status: PurchaseOrder::OPEN).count, b["office"]["open_pos"]
    assert_equal 2, b["office"]["open_pos"]
    assert_equal %w[PO-CMP-5 PO-CMP-4 PO-CMP-3], b["office"]["recent_pos"].map { |o| o["po_no"] }, "발주 시각이 같으면 id 큰 순 3건"
    assert_equal %w[expected_at po_no status supplier], b["office"]["recent_pos"].first.keys.sort
    raw = b["material"]["raw_store"]
    assert_equal raw.map { |r| r["sku"] }, raw.map { |r| r["sku"] }.sort
    assert_equal Quant.where(location: Location.find_by!(code: "receiving")).sum(:qty).to_i, b["material"]["receiving_qty"]
    assert_equal Machine.group(:state).count.fetch("running", 0), b["hall"]["running"]
  end

  test "불합격 없는 검사만 있어도 불합격률은 이동 합계와 맞는다" do
    sign_in_as create_user
    move("produce", product: @fg, lot: @lot, qty: 4, ref: @wo)
    Inventory::Inspect.call(lot: @lot, work_order: @wo, pass_qty: 4, fail_qty: 0, idempotency_key: "cmp-ok")

    get "/api/campus"
    pass = StockMove.where(move_type: "qc_pass", occurred_at: 60.minutes.ago..).sum(:qty)
    fail = StockMove.where(move_type: "qc_fail", occurred_at: 60.minutes.ago..).sum(:qty)
    expected = (fail / (pass + fail)).to_f.round(4)
    assert_equal expected, response.parsed_body["buildings"]["qc"]["defect_ratio_60m"]
  end

  test "쿼리 수는 이동·작업 건수와 무관하게 20개 이하이다" do
    sign_in_as create_user
    run_flow
    30.times { move("receive") }
    30.times { |i| make_task(planned_at: Time.current + i.seconds) }

    [{}, { after_id: @baseline_id }, { after_seq: 0 }, { include: "bins" }, { after_seq: 0, include: "bins" }].each do |params|
      n = count_queries { get "/api/campus", params: params }
      assert_response :ok
      assert_operator n, :<=, MAX_QUERIES, "params=#{params} queries=#{n}"
    end
  end

  test "같은 데이터면 두 번째 요청은 304 이고 새 이동이 생기면 after_id 응답도 200 이다" do
    sign_in_as create_user
    move("receive")

    get "/api/campus", params: { after_id: @baseline_id }
    etag = response.headers["ETag"]
    assert etag.present?

    get "/api/campus", params: { after_id: @baseline_id }, headers: { "If-None-Match" => etag }
    assert_response :not_modified

    move("receive")
    get "/api/campus", params: { after_id: @baseline_id }, headers: { "If-None-Match" => etag }
    assert_response :ok
  end

  test "after_seq 이후 작업만 seq 오름차순으로 최대 100건 오고 last_seq 로 이어서 받는다" do
    sign_in_as create_user
    base = Task.maximum(:seq) || 0
    105.times { |i| make_task(planned_at: Time.current + i.seconds) }

    body = tasks_of(after_seq: base)
    seqs = body["tasks"].map { |t| t["seq"] }
    assert_equal 100, seqs.size
    assert_equal seqs.sort, seqs
    assert seqs.all? { |s| s > base }
    assert_equal seqs.last, body["last_seq"]

    rest = tasks_of(after_seq: body["last_seq"])
    assert_equal Task.where("seq > ?", seqs.last).order(:seq).pluck(:seq), rest["tasks"].map { |t| t["seq"] }
    assert_equal 5, rest["tasks"].size

    none = tasks_of(after_seq: rest["last_seq"])
    assert_equal [], none["tasks"]
    assert_equal rest["last_seq"], none["last_seq"], "새 작업이 없으면 after_seq 를 그대로 돌려준다"
  end

  test "잘못된 after_seq 는 400 이다" do
    sign_in_as create_user
    get "/api/campus", params: { after_seq: "-1" }

    assert_response :bad_request
    assert_equal "invalid_after_seq", response.parsed_body["error"]
  end

  test "작업 항목에 필드 · 시각(밀리초 ISO) · 자원 · ref 가 실린다" do
    sign_in_as create_user
    fork = Resource.find_by!(code: "FORK-01")
    make_task(kind: "putaway", status: "started", resource: fork, planned_at: Time.current, ref_type: "WorkOrder", ref_id: @wo.id)

    task = tasks_of(after_seq: 0)["tasks"].find { |t| t["ref"] == "WO-CMP" }
    keys = %w[id seq kind status resource product lot qty from_code to_code from_building to_building
              planned_at started_at expected_finish_at finished_at ref]
    assert_equal keys.sort, task.keys.sort
    assert_equal({ "code" => "FORK-01", "kind" => "forklift" }, task["resource"])
    assert_equal ["캠퍼스원자재", 1, "receiving", "raw_store"], task.values_at("product", "qty", "from_code", "to_code")
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, task["started_at"])
    assert_nil task["finished_at"]
  end

  test "첫 진입은 진행 중 작업 전부와 최근 완료 20건을 seq 오름차순으로 준다" do
    sign_in_as create_user
    t0 = Time.current - 2.hours
    25.times { |i| make_task(status: "done", planned_at: t0 + i.minutes) }
    old_cancelled = make_task(status: "cancelled", planned_at: t0)
    planned = Array.new(3) { make_task(planned_at: Time.current + 1.minute) }
    started = Array.new(2) { make_task(status: "started", resource: Resource.find_by!(code: "FORK-01"), planned_at: Time.current) }

    body = tasks_of
    tasks = body["tasks"]
    ids = tasks.map { |t| t["id"] }
    in_progress = (planned + started).map(&:id)
    done_ids = Task.where(status: "done").order(finished_at: :desc, id: :desc).limit(20).pluck(:id)

    assert_equal (in_progress + done_ids).sort, ids.sort
    assert_equal 25, ids.size
    assert_not_includes ids, old_cancelled.id
    assert_equal tasks.map { |t| t["seq"] }.sort, tasks.map { |t| t["seq"] }
    assert_equal tasks.last["seq"], body["last_seq"]
  end

  test "위치 조상으로 건물을 판정한다 (위치 10종 + 칸)" do
    sign_in_as create_user
    expected = {
      %w[supplier receiving] => %w[gate material],
      %w[RAW-A-01-01 line_side] => %w[material hall],
      %w[line_side production] => %w[hall hall],
      %w[qc scrap] => %w[qc qc],
      %w[qc FG-A-02-03] => %w[qc shipping_wh],
      %w[FG-A-02-03 shipping] => %w[shipping_wh shipping_dock],
      %w[shipping customer] => %w[shipping_dock gate],
      %w[raw_store receiving] => %w[material material],
      %w[fg_store qc] => %w[shipping_wh qc]
    }
    expected.each_key { |from, to| make_task(from: from, to: to) }

    tasks = tasks_of(after_seq: 0)["tasks"].select { |t| expected.key?([t["from_code"], t["to_code"]]) }
    assert_equal expected.size, tasks.size
    tasks.each do |t|
      assert_equal expected.fetch([t["from_code"], t["to_code"]]), t.values_at("from_building", "to_building"),
                   "#{t['from_code']} -> #{t['to_code']}"
    end
  end

  test "자원 12개가 오고 started 작업이 있는 자원만 busy 이다" do
    sign_in_as create_user
    fork = Resource.find_by!(code: "FORK-01")
    running = make_task(status: "started", resource: fork)
    make_task(resource: Resource.find_by!(code: "FORK-02")) # planned 는 idle

    resources = tasks_of["resources"]
    assert_equal 12, resources.size
    assert_equal %w[code current_task_id home_building kind status], resources.first.keys.sort
    by_code = resources.index_by { |r| r["code"] }
    assert_equal ["busy", running.id, "material"], by_code["FORK-01"].values_at("status", "current_task_id", "home_building")
    assert_equal ["idle", nil], by_code["FORK-02"].values_at("status", "current_task_id")
    assert_equal "shipping_dock", by_code["DOCK-OUT-01"]["home_building"]
    assert_equal "material", by_code["DOCK-IN-01"]["home_building"]
    assert_equal "hall", by_code["WORKER-01"]["home_building"]
  end

  test "bins 는 include=bins 일 때만 오고 칸별 위치·용량·재고가 맞다" do
    sign_in_as create_user
    assert_not tasks_of.key?("bins")
    assert_not tasks_of(include: "other").key?("bins")

    bin = Location.find_by!(code: "RAW-A-02-03")
    Quant.create!(product: @raw, location: bin, qty: 7)
    held = make_task(kind: "feed", from: "RAW-A-02-03", to: "line_side", qty: 3)
    Reservation.create!(task: held, product: @raw, location: bin, qty: 3)
    done = make_task(kind: "feed", status: "done", from: "RAW-A-02-03", to: "line_side", qty: 2)
    Reservation.create!(task: done, product: @raw, location: bin, qty: 2, status: "consumed") # 끝난 예약은 reserved 에 안 든다

    bins = tasks_of(include: "bins")["bins"]
    assert_equal %w[fg raw], bins.keys.sort
    assert_equal 24, bins["raw"].size
    assert_equal 24, bins["fg"].size
    row = bins["raw"].find { |b| b["code"] == "RAW-A-02-03" }
    assert_equal({ "code" => "RAW-A-02-03", "rack" => "RAW-A-02", "level" => 3, "capacity" => bin.capacity_units,
                   "qty" => 7, "reserved" => 3, "product" => "RAW-CMP" }, row)
    empty = bins["fg"].find { |b| b["code"] == "FG-A-01-01" }
    assert_equal [1, 0, 0, nil], empty.values_at("level", "qty", "reserved", "product")
  end

  test "bins 의 reserved 는 쿼리를 1개만 더한다(칸 수와 무관)" do
    sign_in_as create_user
    bin = Location.find_by!(code: "RAW-A-01-01")
    Quant.create!(product: @raw, location: bin, qty: 7)
    base = count_queries { get "/api/campus", params: { include: "bins" } }
    20.times do |i|
      task = make_task(kind: "feed", from: "RAW-A-01-01", to: "line_side", planned_at: Time.current + i.seconds)
      Reservation.create!(task: task, product: @raw, location: bin, qty: 1)
    end
    assert_equal base, count_queries { get "/api/campus", params: { include: "bins" } }
  end

  test "ETag 는 server_time 에 흔들리지 않고 새 작업이 생기면 바뀐다" do
    sign_in_as create_user
    make_task
    get "/api/campus", params: { after_seq: 0 }
    etag = response.headers["ETag"]
    assert etag.present?

    get "/api/campus", params: { after_seq: 0 }, headers: { "If-None-Match" => etag }
    assert_response :not_modified

    make_task
    get "/api/campus", params: { after_seq: 0 }, headers: { "If-None-Match" => etag }
    assert_response :ok
  end

  test "include=bins 응답은 칸 재고가 바뀌면 ETag 도 바뀐다" do
    sign_in_as create_user
    get "/api/campus", params: { include: "bins" }
    etag = response.headers["ETag"]

    get "/api/campus", params: { include: "bins" }, headers: { "If-None-Match" => etag }
    assert_response :not_modified

    Quant.create!(product: @raw, location: Location.find_by!(code: "RAW-A-01-01"), qty: 3)
    get "/api/campus", params: { include: "bins" }, headers: { "If-None-Match" => etag }
    assert_response :ok
  end
end
