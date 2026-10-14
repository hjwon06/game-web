# 거리 읽기 API 테스트 공용 도구. IntegrationTest 에 include 한다(get · response · @street_now 를 쓴다).
module SecStreetHelpers
  KST = ActiveSupport::TimeZone["Asia/Seoul"]
  STARTED = Time.utc(2026, 10, 1, 0, 0, 0)
  DAY = Date.new(2026, 11, 2)
  API = "/api/sec/street".freeze

  def write_state(cursor: nil)
    state = { "started_at" => STARTED.iso8601(9) }
    state.merge!("cursor" => cursor.iso8601(9), "cursor_r" => cursor.to_r.to_s) if cursor
    File.write(Api::SecStreetController.state_path, JSON.generate(state))
  end

  def market_now
    Securities::Clock.market_time(@street_now, started_at: STARTED, first_day: DAY)
  end

  def market_at(real)
    Securities::Clock.market_time(real, started_at: STARTED, first_day: DAY)
  end

  def street(params = {}, headers = {})
    get API, params: params, headers: headers
    response.parsed_body
  end

  def at(hour, min, sec = 0)
    KST.local(2026, 11, 2, hour, min, sec)
  end

  def clock_at(real)
    @street_now = real
    street["clock"].values_at("market_time", "phase", "trade_date")
  end

  # 투자자 둘(VINV-001 = 집 0, VINV-006 = 집 1) · 5종목.
  def build_market(cash: 10_000_000)
    @cash = Securities::Asset.create!(code: "VKRW", name: "가상원화", kind: "cash")
    @eq = Securities::Seed::EQUITIES.to_h do |code, name, price|
      [code, Securities::Asset.create!(code: code, name: name, kind: "equity", base_price: price)]
    end
    @a1 = Securities::Account.create!(code: "VINV-001", name: "가상투자자 001", kind: "investor")
    @a6 = Securities::Account.create!(code: "VINV-006", name: "가상투자자 006", kind: "investor")
    Securities::Position.create!(account: @a1, asset: @cash, qty: cash)
    { "VELEC" => 12, "VBIO" => 5 }.each { |code, qty| Securities::Position.create!(account: @a6, asset: @eq[code], qty: qty) }
    @n = 0
  end

  def put_order(account, side, code, price, qty, time)
    Securities::PlaceOrder.call(account: account, asset: @eq.fetch(code), side: side, order_type: "limit", qty: qty,
                                price: price, client_key: "t-#{@n += 1}", at: time)
  end

  def open_auctions
    %w[VELEC VBIO].each { |c| Securities::Auction.open!(asset: @eq[c], trade_date: DAY, at: at(9, 0, 20), single_price: true) }
  end

  # 손계산 대상. 주문 12(거절 4 · 취소 1) · 체결 3(시가 단일가 1 + 접속 2).
  def build_day
    build_market
    put_order(@a1, "buy", "VELEC", 72_000, 1, at(8, 10)) # closed
    put_order(@a1, "buy", "VELEC", 72_000, 1, at(8, 45)) # 장전 접수 → 시가 단일가 72,000 × 1
    put_order(@a6, "sell", "VELEC", 72_000, 1, at(8, 46))
    open_auctions
    put_order(@a1, "buy", "VELEC", 72_000, 10, at(10, 0)) # 아래 4 체결 → 6 남음
    put_order(@a1, "buy", "VBIO", 258_000, 2, at(10, 0, 10))
    put_order(@a6, "sell", "VELEC", 72_000, 4, at(10, 1, 10))
    put_order(@a6, "sell", "VBIO", 255_000, 2, at(10, 1, 20)) # 먼저 있던 매수가 258,000 × 2
    put_order(@a6, "sell", "VELEC", 73_000, 5, at(10, 1, 30)) # 안 맞고 남는다
    @cancelled = put_order(@a1, "buy", "VELEC", 71_000, 3, at(10, 1, 40))
    put_order(@a1, "buy", "VELEC", 72_050, 1, at(10, 1, 45)) # tick
    put_order(@a1, "buy", "VELEC", 94_000, 1, at(10, 1, 50)) # price_limit(상한 93,600)
    put_order(@a1, "buy", "VELEC", 72_000, 1_000, at(10, 1, 55)) # insufficient
    Securities::CancelOrder.call(order: @cancelled, at: at(10, 2, 0))
    write_state(cursor: market_now)
  end

  # 통합 테스트는 요청 사이에 쿼리 캐시가 남아 두 번째 요청이 전부 캐시로 나간다. 세기 전에 두 연결을 비운다.
  def count_queries
    [ActiveRecord::Base, Securities::Record].each { |base| base.lease_connection.clear_query_cache }
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end
end
