require "test_helper"
require "tmpdir"
require_relative "../../support/sec_street_helpers"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# 거리 읽기 API. 시계는 주입한다: 실시간 = STARTED + k 초, 가상 = 11-02 08:30 + 12k 초(장중). k = 465 → 가상 10:03:00.
# 변이 검사: stale 부등호 <= → T2 15초 경계 · 15 → 1500 → T2 장중 · reconcile rescue → T3 reconcile 예외 · 직전 영업일 → T2 08:10 · 열린 상태 목록 → T3 board · ETag 에 server_time → T5.
class SecStreetControllerTest < ActionDispatch::IntegrationTest
  include SecStreetHelpers

  KEYS = %w[server_time clock board today orders last_seq executions last_exec settlements reconcile].freeze

  setup do
    @dir = Dir.mktmpdir("sec_street")
    @saved = %i[state_path now_source cache_store].to_h { |k| [k, Api::SecStreetController.public_send(k)] }
    Api::SecStreetController.state_path = File.join(@dir, "state.json")
    Api::SecStreetController.now_source = -> { @street_now }
    Api::SecStreetController.cache_store = ActiveSupport::Cache::MemoryStore.new
    @street_now = STARTED + 465 # 가상 2026-11-02 10:03:00
    Securities::Calendar.extend!(through: Date.new(2026, 11, 13))
    sign_in_as create_user
  end

  teardown do
    @saved.each { |k, v| Api::SecStreetController.public_send(:"#{k}=", v) }
    FileUtils.remove_entry(@dir)
  end

  test "T1 비로그인은 401 JSON, 로그인하면 200 이고 최상위 키가 이름 그대로 다 있다" do
    assert_equal KEYS.sort, street.keys.sort
    assert_response :ok
    delete "/logout"
    get API
    assert_response :unauthorized
    assert_equal "login_required", response.parsed_body["error"]
  end

  test "T2 상태 파일이 없으면 clock 은 null 이고 나머지 키는 있다" do
    body = street

    assert_nil body["clock"]
    assert_equal KEYS.sort, body.keys.sort
    assert_equal [[], 0, nil], [body["orders"], body["last_seq"], body["reconcile"]]
    rejected = { "insufficient" => 0, "price_limit" => 0, "tick" => 0, "closed" => 0 }
    assert_equal({ "orders" => 0, "executions" => 0, "value" => 0, "rejected" => rejected, "cancelled" => 0 }, body["today"])
  end

  test "T2 장중: continuous · speed_now 12 · 거래일 · cursor. stale 는 실시간 15초 기준(정확히 15초 아님 · 1초(가상) 앞 · cursor 없음)" do
    write_state(cursor: market_now - 30)
    clock = street["clock"]
    assert_equal ["2026-11-02T10:03:00.000+09:00", "continuous", 12, "2026-11-02", "2026-11-02T10:02:30.000+09:00", false],
                 clock.values_at("market_time", "phase", "speed_now", "trade_date", "cursor", "stale")
    limit = market_at(@street_now - 15) # 가상 09:57:00
    write_state(cursor: limit)
    assert_equal false, street["clock"]["stale"]
    write_state(cursor: limit - 1)
    assert_equal true, street["clock"]["stale"]
    write_state(cursor: market_now - 12) # 실시간 1초 뒤
    assert_equal false, street["clock"]["stale"]
    write_state
    assert_equal [nil, true], street["clock"].values_at("cursor", "stale")
  end

  test "T2 밤(약 204배속): cursor 가 실시간 1초 뒤(가상 약 204초)여도 stale 가 아니고, 실시간 16초 뒤면 stale 다" do
    @street_now = STARTED + 2100 + Rational(300 * 60_000, 61_200) # 가상 11-03 08:10, 마감 뒤 밤
    write_state(cursor: market_at(@street_now - 1))
    clock = street["clock"]
    assert_operator clock["speed_now"], :>, 200
    assert_equal false, clock["stale"]
    write_state(cursor: market_at(@street_now - 16))
    assert_equal true, street["clock"]["stale"]
  end

  test "T2 막 켬: 지금 − 15초가 시작 전이면 cursor 가 있는 한 stale 가 아니다(cursor 없음은 stale)" do
    @street_now = STARTED + 10
    write_state(cursor: market_at(STARTED))
    assert_equal false, street["clock"]["stale"]
    write_state
    assert_equal true, street["clock"]["stale"]
  end

  test "T3 reconcile 이 예외를 내면 200 이고 reconcile 은 null, 나머지는 그대로이며 캐시에 남지 않는다" do
    build_day
    calls = 0
    Api::SecStreetController.reconcile_source = ->(**) { (calls += 1) == 1 ? raise("대사 깨짐") : [] }
    body = street

    assert_response :ok
    assert_nil body["reconcile"]
    assert_equal KEYS.sort, body.keys.sort
    assert_equal %w[VELEC VBIO VBANK VCONS VGAME], body["board"].map { |r| r["code"] }
    assert_equal 12, body["today"]["orders"]
    assert_equal 0, street["reconcile"] # (주입이 [] 를 돌려준다) 실패가 캐시되지 않아 다음 요청이 다시 계산한다
    assert_equal 2, calls
  ensure
    Api::SecStreetController.reconcile_source = nil
  end

  test "T2 08:30 전과 휴장일은 직전 영업일이다(가상 08:10 · 08:30 정각 · 토요일 정오)" do
    write_state

    assert_equal ["2026-11-03T08:10:00.000+09:00", "closed", "2026-11-02"],
                 clock_at(STARTED + 2100 + Rational(300 * 60_000, 61_200)) # 11-02 마감 → 11-03 08:10
    assert_equal ["2026-11-03T08:30:00.000+09:00", "pre_open", "2026-11-03"], clock_at(STARTED + 2400)
    assert_equal ["2026-11-07T12:00:00.000+09:00", "closed", "2026-11-06"],
                 clock_at(STARTED + 11_700 + Rational(300 * 73_800, 234_000)) # 금 15:30 마감 + 20.5시간
  end

  test "T3 board 는 Seed 순서 5종목이고 체결 · 열린 주문 · today 를 손계산과 맞춘다" do
    build_day
    body = street
    board = body["board"]

    assert_equal %w[VELEC VBIO VBANK VCONS VGAME], board.map { |r| r["code"] }
    velec, bio, bank = board.first(3)
    assert_equal [72_000, 72_000, 0, 5, 360_000], velec.values_at("base_price", "last_price", "change", "volume", "value")
    assert_equal [72_000, 73_000, 6, 5, 2], velec.values_at("best_bid", "best_ask", "open_buy_qty", "open_sell_qty", "open_orders")
    assert_equal [260_000, 258_000, -2_000, 2, 516_000], bio.values_at("base_price", "last_price", "change", "volume", "value")
    assert_equal [nil, nil, 0, 0, 0], bio.values_at("best_bid", "best_ask", "open_buy_qty", "open_sell_qty", "open_orders")
    assert_equal [18_000, 18_000, 0, 0, 0, nil, nil, 0], bank.values_at("base_price", "last_price", "change", "volume", "value",
                                                                       "best_bid", "best_ask", "open_orders")
    today = body["today"]
    assert_equal [12, 3, 876_000, 1], today.values_at("orders", "executions", "value", "cancelled")
    assert_equal({ "insufficient" => 1, "price_limit" => 1, "tick" => 1, "closed" => 1 }, today["rejected"])
  end

  test "T3 orders · executions: 키 · house(집 = (번호−1)/5) · 거절 사유 · 세션, 커서가 없으면 120초 창" do
    build_day
    body = street(after_seq: "0", after_exec: "0")
    by_price = body["orders"].group_by { |o| [o["side"], o["price"], o["qty"]] }

    assert_equal 12, body["orders"].size
    assert_equal body["orders"].map { |o| o["seq"] }.sort, body["orders"].map { |o| o["seq"] }
    assert_equal %w[seq asset side order_type price qty status reject_reason accepted_at house], body["orders"].first.keys
    assert_equal ["VELEC", "limit", "filled", nil, "2026-11-02T10:01:10.000+09:00", 1],
                 by_price.fetch(["sell", 72_000, 4]).first.values_at("asset", "order_type", "status", "reject_reason", "accepted_at", "house")
    assert_equal ["rejected", "tick", 0], by_price.fetch(["buy", 72_050, 1]).first.values_at("status", "reject_reason", "house")
    assert_equal "closed", body["orders"].first["reject_reason"]
    assert_equal %w[id asset price qty executed_at session], body["executions"].first.keys
    assert_equal [%w[VELEC open], %w[VELEC continuous], %w[VBIO continuous]], body["executions"].map { |e| e.values_at("asset", "session") }
    assert_equal [72_000, 72_000, 258_000], body["executions"].map { |e| e["price"] }
    window = street # 10:01:00 이후: 주문 7 · 체결 2
    assert_equal [7, 2], [window["orders"].size, window["executions"].size]
    assert_equal [Securities::Order.maximum(:seq), Securities::Execution.maximum(:id)], window.values_at("last_seq", "last_exec")
  end

  test "T3 house 경계: VINV-005 는 0, VINV-010 은 1 이다(번호 / 5 면 1 · 2)" do
    build_market
    open_auctions
    { "VINV-005" => 1, "VINV-010" => 2 }.each do |code, qty|
      account = Securities::Account.create!(code: code, name: "가상투자자 #{code[-3..]}", kind: "investor")
      Securities::Position.create!(account: account, asset: @cash, qty: 10_000_000)
      put_order(account, "buy", "VBIO", 255_000, qty, at(10, 0))
    end
    write_state(cursor: market_now)
    houses = street(after_seq: "0", after_exec: "0")["orders"].to_h { |o| [o["qty"], o["house"]] }

    assert_equal({ 1 => 0, 2 => 1 }, houses)
  end

  test "T3 같은 종목 같은 날 last_price · change 는 가격이 아니라 나중 체결이다(72,300 → 71,900 → 72,100)" do
    # 마지막 값이 최고가도 최저가도 첫 체결도 아니어야 MAX · MIN · ASC 변이가 전부 실패한다
    build_market
    open_auctions
    put_order(@a1, "buy", "VELEC", 72_300, 1, at(10, 0))
    put_order(@a6, "sell", "VELEC", 72_300, 1, at(10, 0, 10))
    put_order(@a1, "buy", "VELEC", 71_900, 1, at(10, 1))
    put_order(@a6, "sell", "VELEC", 71_900, 1, at(10, 1, 10))
    put_order(@a1, "buy", "VELEC", 72_100, 1, at(10, 2))
    put_order(@a6, "sell", "VELEC", 72_100, 1, at(10, 2, 10))
    write_state(cursor: market_now)
    velec = street["board"].first

    assert_equal [72_000, 72_100, 100, 3, 216_300], velec.values_at("base_price", "last_price", "change", "volume", "value")
  end

  test "T3 settlements 최근 3건(날짜 내림) · 원장 행 수 · reconcile 어긋남 수" do
    build_day
    rows = [[2, "settled"], [3, "settled"], [4, "pending"], [5, "pending"]].map do |day, status|
      Securities::Settlement.create!(settle_date: Date.new(2026, 11, day), status: status, settled_at: (status == "settled" ? at(16, 0) : nil))
    end
    2.times do |i|
      Securities::LedgerEntry.create!(settlement: rows[2], from_account: @a1, to_account: @a6, asset: @cash, qty: 10 + i, idem_key: "led-#{i}")
    end
    body = street

    assert_equal %w[2026-11-05 2026-11-04 2026-11-03], body["settlements"].map { |s| s["settle_date"] }
    assert_equal [0, 2, 0], body["settlements"].map { |s| s["entries"] }
    assert_equal %w[pending pending settled], body["settlements"].map { |s| s["status"] }
    assert_equal [nil, nil, "2026-11-02T16:00:00.000+09:00"], body["settlements"].map { |s| s["settled_at"] }
    # 원장이 없는데 positions 가 있는 3줄(VINV-001 현금 · VINV-006 VELEC · VBIO) + 방금 넣은 원장만 있는 VINV-006 현금 1줄.
    assert_equal 4, body["reconcile"]
    assert_equal 4, Securities::Reconcile.call(as_of: DAY).size
  end

  test "T4 커서 증분: 마지막 이후만 오고, 새 것이 없으면 커서가 그대로다" do
    build_day
    first = street(after_seq: "0", after_exec: "0")
    put_order(@a6, "sell", "VELEC", 72_000, 2, at(10, 2, 10)) # b1 에 2주 체결
    more = street(after_seq: first["last_seq"].to_s, after_exec: first["last_exec"].to_s)

    assert_equal [[72_000, 2]], more["orders"].map { |o| o.values_at("price", "qty") }
    assert_equal [[72_000, 2]], more["executions"].map { |e| e.values_at("price", "qty") }
    assert_equal Securities::Order.maximum(:seq), more["last_seq"]
    again = street(after_seq: more["last_seq"].to_s, after_exec: more["last_exec"].to_s)
    assert_equal [[], [], more["last_seq"], more["last_exec"]], again.values_at("orders", "executions", "last_seq", "last_exec")
  end

  test "T4 한 번에 최대 300건이고 last_seq · last_exec 로 이어 받으면 빠짐 · 겹침이 없다" do
    build_market
    now = at(10, 1, 30)
    Securities::Order.insert_all(Array.new(310) do |i|
      { client_key: "cap-#{i}", account_id: @a1.id, asset_id: @eq["VELEC"].id, side: "buy", order_type: "limit",
        price: 72_000, qty: 1, status: "accepted", accepted_at: now }
    end)
    ids = Securities::Order.order(:seq).limit(2).pluck(:id)
    Securities::Execution.insert_all(Array.new(310) do |i|
      { asset_id: @eq["VELEC"].id, buy_order_id: ids[0], sell_order_id: ids[1], price: 72_000, qty: 1,
        executed_at: now + i, trade_date: DAY, settle_date: DAY + 2 }
    end)

    page1 = street(after_seq: "0", after_exec: "0")
    assert_equal [300, 300], [page1["orders"].size, page1["executions"].size]
    assert_equal [page1["orders"].last["seq"], page1["executions"].last["id"]], page1.values_at("last_seq", "last_exec")
    page2 = street(after_seq: page1["last_seq"].to_s, after_exec: page1["last_exec"].to_s)
    assert_equal [10, 10], [page2["orders"].size, page2["executions"].size]
    assert_empty page1["orders"].map { |o| o["seq"] } & page2["orders"].map { |o| o["seq"] }
    assert_equal Securities::Order.maximum(:seq), page2["last_seq"]
  end

  test "T4 잘못된 커서는 400 이다(문자 · 음수 · 소수 · 빈 값 · 공백 · 배열 · 너무 큰 수)" do
    ["abc", "-1", "1.5", "", "1 ", "9" * 40].each do |bad|
      get API, params: { after_seq: bad }
      assert_response :bad_request, "after_seq=#{bad.inspect}"
      assert_equal ["bad_cursor", "after_seq"], response.parsed_body.values_at("error", "param")
    end
    get API, params: { after_exec: "x" }
    assert_response :bad_request
    get "#{API}?after_seq[]=1"
    assert_response :bad_request
  end

  test "T5 같은 상태에 If-None-Match 를 보내면 304(본문 없음). 데이터가 바뀌면 200 이고 ETag 도 바뀐다" do
    build_day
    street
    etag = response.headers["ETag"]
    assert_predicate etag, :present?

    get API, headers: { "If-None-Match" => etag }
    assert_response :not_modified
    assert_empty response.body
    put_order(@a1, "buy", "VBIO", 255_000, 1, at(10, 2, 20))
    get API, headers: { "If-None-Match" => etag }
    assert_response :ok
    assert_not_equal etag, response.headers["ETag"]
  end

  test "T5 ETag 는 server_time 을 뺀 본문이다(시계가 없어 본문이 같고 시각만 다르면 304)" do
    first = street
    etag = response.headers["ETag"]
    @street_now += 5
    assert_equal 5, Time.iso8601(street["server_time"]) - Time.iso8601(first["server_time"])
    get API, headers: { "If-None-Match" => etag }
    assert_response :not_modified
  end

  test "T5 쿼리 수는 주문 30건과 300건에서 같고 reconcile 은 캐시가 맞는다" do
    build_market(cash: 1_000_000_000)
    open_auctions
    write_state(cursor: market_now)
    fill = ->(count) { count.times { put_order(@a1, "buy", "VELEC", 72_000, 1, at(10, 1, 30)) } }

    fill.call(30)
    miss = count_queries { street }
    hit30 = count_queries { street }
    fill.call(270)
    body = nil
    hit300 = count_queries { body = street }

    assert_equal 300, body["orders"].size
    assert_equal hit30, hit300
    assert_operator miss, :>, hit30, "첫 요청만 Reconcile 쿼리를 쓴다"
  end

  test "A7 인덱스: orders(accepted_at) · 열린 주문 부분 인덱스(asset_id, side)" do
    indexes = Securities::Record.lease_connection.indexes("orders").index_by(&:name)

    assert_equal ["accepted_at"], indexes.fetch("orders_accepted_at_idx").columns
    open = indexes.fetch("orders_open_asset_side_idx")
    assert_equal %w[asset_id side], open.columns
    assert_match(/accepted.+partially_filled/, open.where)
  end
end
