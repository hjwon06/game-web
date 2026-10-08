require "test_helper"

class CampusControllerTest < ActionDispatch::IntegrationTest
  MAX_QUERIES = 15

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

  # 생산 10 -> 검사 합격 8 / 불합격 2 -> 출하 5
  def run_flow
    move("produce", product: @fg, lot: @lot, qty: 10, ref: @wo)
    Inventory::Inspect.call(lot: @lot, work_order: @wo, pass_qty: 8, fail_qty: 2, idempotency_key: "cmp-insp")
    Inventory::Ship.call(sales_order_line: @line, lot: @lot, qty: 5, idempotency_key: "cmp-ship")
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
    assert_equal %w[buildings last_move_id moves sim_note], body.keys.sort
    assert_equal %w[hall material office qc shipping], body["buildings"].keys.sort
    assert_equal %w[orders recent], body["buildings"]["office"].keys.sort
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
    assert_equal ["fg_store", "customer", "SO-CMP", 5], ship.values_at("from_code", "to_code", "ref", "qty")
    assert_equal "WO-CMP", pass["ref"]
    assert_nil moves.find { |m| m["type"] == "receive" }
  end

  test "건물 숫자가 DB 와 맞는다 (수주 상태, 불합격률, 출하, 입고)" do
    sign_in_as create_user
    run_flow
    2.times { move("receive", qty: 7) }

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

    assert_equal StockMove.where(move_type: "receive", occurred_at: 10.minutes.ago..).count,
                 b["material"]["received_trucks_10m"]
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

  test "쿼리 수는 이동 건수와 무관하게 15개 이하이다" do
    sign_in_as create_user
    run_flow
    30.times { move("receive") }

    [{}, { after_id: @baseline_id }].each do |params|
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
end
