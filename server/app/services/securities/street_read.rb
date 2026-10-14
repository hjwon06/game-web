# 거리 화면(⑦)이 읽는 한 장짜리 스냅숏. 읽기만 한다. 시뮬레이터 규칙이다(숫자는 아래 상수 한 곳).
# 쿼리 수는 데이터 크기와 무관하다. 전부 "GROUP BY 한 번" 또는 "LIMIT 이 걸린 한 번"이다.
#   clock  1(MarketDay.exists?) + 1~2(days_from) 을 market_time 두 번 + Phase 1 + trade_date 1
#   board  assets 1 · 체결 집계 1(executions.trade_date 인덱스) · 열린 주문 집계 1(부분 인덱스)
#   today  주문 집계 1(accepted_at 인덱스)       orders/executions  각 1(+ 창 모드면 max 1)
#   settlements 1      reconcile  캐시 적중 0 · 실패 시에만 Reconcile 의 쿼리
# 상태 파일(Sim::Daemon 이 쓴다)이 없거나 읽을 수 없으면 clock 은 nil 이고 거래일을 모르므로
# 체결 · 오늘 집계 · 창 목록 · 대사는 비운다(키는 그대로 있다). 열린 주문 · 결제는 날짜와 무관해 그대로 읽는다.
module Securities
  class StreetRead
    WINDOW_SECONDS = 120 # 커서가 없을 때 가상 지금에서 거슬러 올라가는 폭
    PAGE_LIMIT = 300
    STALE_SECONDS = 60 # 가상 지금 − cursor 가 이보다 크면 데몬이 멈춘 것으로 본다
    SETTLEMENT_COUNT = 3
    RECONCILE_TTL = 10.seconds
    RECONCILE_RACE_TTL = 5.seconds
    HOUSE_SIZE = 5 # 투자자 5명이 한 집
    REJECT_KEYS = %w[insufficient price_limit tick closed].freeze
    # 부분 인덱스(orders_open_asset_side_idx)의 WHERE 와 같은 식을 리터럴로 쓴다. 바인드 파라미터면 일반 계획에서 인덱스를 못 쓴다.
    OPEN_SQL = "status IN (#{Order::CANCELLABLE.map { |s| "'#{s}'" }.join(',')})".freeze

    class BadCursor < StandardError
      attr_reader :param

      def initialize(param)
        @param = param
        super("#{param} 는 0 이상의 정수여야 한다")
      end
    end

    Snapshot = Struct.new(:market_time, :phase, :trade_date, :speed_now, :cursor, :stale)

    def initialize(state_path:, now:, cache:)
      @state_path = Pathname(state_path)
      @now = now
      @cache = cache
    end

    def call(after_seq: nil, after_exec: nil)
      seq = parse_cursor(after_seq, "after_seq")
      exec_id = parse_cursor(after_exec, "after_exec")
      clock = read_clock
      day = clock&.trade_date
      trades = trades_by_asset(day)
      orders, last_seq = orders_page(seq, clock&.market_time)
      executions, last_exec = executions_page(exec_id, clock&.market_time, day)

      { clock: clock && clock_hash(clock), board: board(trades), today: today(day, trades),
        orders: orders, last_seq: last_seq, executions: executions, last_exec: last_exec,
        settlements: settlements, reconcile: reconcile_count(day) }
    end

    private

    def parse_cursor(raw, param)
      return nil if raw.nil?
      raise BadCursor, param unless raw.is_a?(String) && raw.match?(/\A\d{1,18}\z/)

      raw.to_i
    end

    # --- clock ---------------------------------------------------------------

    def read_state
      return nil unless @state_path.file?

      JSON.parse(@state_path.read)
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def read_clock
      state = read_state
      return nil unless state.is_a?(Hash) && state["started_at"]

      started = Time.iso8601(state["started_at"])
      real = @now
      first = Seed::FIRST_MARKET_DAY
      market = Clock.market_time(real, started_at: started, first_day: first)
      ahead = Clock.market_time(real + 1, started_at: started, first_day: first)
      cursor = parse_state_cursor(state)
      Snapshot.new(market, Phase.at(market), trade_date_of(market), speed_of(ahead.to_r - market.to_r), cursor,
                   cursor.nil? || (market.to_r - cursor.to_r) > STALE_SECONDS)
    rescue ArgumentError, Calendar::Missing # 시계가 시작 전이거나 달력이 모자라다 = 시계를 읽을 수 없다
      nil
    end

    def parse_state_cursor(state)
      return Time.at(Rational(state["cursor_r"])).in_time_zone(Phase::ZONE) if state["cursor_r"]

      state["cursor"] && Time.iso8601(state["cursor"]).in_time_zone(Phase::ZONE)
    end

    # 08:30 이후면 그날(휴장일이면 직전 영업일), 08:30 전이면 날짜 앞의 영업일 중 마지막.
    def trade_date_of(market)
      local = market.in_time_zone(Phase::ZONE)
      date = local.to_date
      opened = local.hour * 60 + local.min >= Phase::SCHEDULE.first[1]
      MarketDay.where(business_day: true).where("trade_date #{opened ? '<=' : '<'} ?", date).maximum(:trade_date) || date
    end

    def speed_of(seconds)
      seconds.denominator == 1 ? seconds.to_i : seconds.to_f.round(3)
    end

    def clock_hash(clock)
      { market_time: iso(clock.market_time), phase: clock.phase.to_s, trade_date: clock.trade_date.iso8601,
        speed_now: clock.speed_now, cursor: clock.cursor && iso(clock.cursor), stale: clock.stale }
    end

    def iso(time)
      time.in_time_zone(Phase::ZONE).iso8601(3)
    end

    # --- board · today -------------------------------------------------------

    # asset_id => { n:, qty:, value:, last: }. 거래일 체결 전부를 GROUP BY 한 번에 줄인다.
    def trades_by_asset(day)
      return {} unless day

      rows = Execution.where(trade_date: day).group(:asset_id).pluck(
        :asset_id, Arel.sql("COUNT(*)"), Arel.sql("SUM(qty)"), Arel.sql("SUM(price * qty)"),
        Arel.sql("(ARRAY_AGG(price ORDER BY executed_at DESC, id DESC))[1]")
      )
      rows.to_h { |id, n, qty, value, last| [id, { n: n.to_i, qty: qty.to_i, value: value.to_i, last: last.to_i }] }
    end

    # [asset_id, side] => [개수, 남은 수량, 최고가, 최저가]
    def open_by_side
      rows = Order.where(Arel.sql(OPEN_SQL)).group(:asset_id, :side).pluck(
        :asset_id, :side, Arel.sql("COUNT(*)"), Arel.sql("SUM(qty - filled_qty)"), Arel.sql("MAX(price)"), Arel.sql("MIN(price)")
      )
      rows.to_h { |id, side, n, rest, max, min| [[id, side], [n.to_i, rest.to_i, max, min]] }
    end

    def board(trades)
      assets = Asset.where(code: Seed::EQUITIES.map(&:first)).index_by(&:code)
      open = open_by_side
      Seed::EQUITIES.filter_map do |code, name, _|
        asset = assets[code]
        asset && board_row(asset, name, trades[asset.id], open[[asset.id, "buy"]], open[[asset.id, "sell"]])
      end
    end

    def board_row(asset, name, trade, buys, sells)
      last = trade ? trade[:last] : asset.base_price
      { code: asset.code, name: name, base_price: asset.base_price, last_price: last, change: last - asset.base_price,
        volume: trade ? trade[:qty] : 0, value: trade ? trade[:value] : 0,
        best_bid: buys && buys[2], best_ask: sells && sells[3],
        open_buy_qty: buys ? buys[1] : 0, open_sell_qty: sells ? sells[1] : 0,
        open_orders: (buys ? buys[0] : 0) + (sells ? sells[0] : 0) }
    end

    # 거래일 달력 하루(KST 00:00 ~ 다음 날 00:00)에 접수된 주문. 체결은 board 의 집계를 다시 쓴다.
    def today(day, trades)
      counts = day ? day_order_counts(day) : {}
      rejected = REJECT_KEYS.to_h { |reason| [reason, counts.select { |(_, r), _| r == reason }.values.sum] }
      { orders: counts.values.sum, executions: trades.values.sum { |t| t[:n] }, value: trades.values.sum { |t| t[:value] },
        rejected: rejected, cancelled: counts.select { |(status, _), _| status == "cancelled" }.values.sum }
    end

    def day_order_counts(day)
      from = Clock::ZONE.local(day.year, day.month, day.day)
      Order.where(accepted_at: from...(from + 1.day)).group(:status, :reject_reason).count
    end

    # --- orders · executions -------------------------------------------------

    ORDER_COLUMNS = %w[orders.seq assets.code accounts.code orders.side orders.order_type orders.price orders.qty
                       orders.status orders.reject_reason orders.accepted_at].freeze
    EXEC_COLUMNS = %w[executions.id assets.code executions.price executions.qty executions.executed_at auctions.session].freeze
    # 체결 시각이 그 종목 그날 단일가 확정 시각(auctions.ran_at)과 같으면 그 세션이다. 한 문장이라 쿼리 수가 늘지 않는다.
    AUCTION_JOIN = "LEFT JOIN auctions ON auctions.asset_id = executions.asset_id " \
                   "AND auctions.trade_date = executions.trade_date AND auctions.ran_at = executions.executed_at".freeze

    # 커서가 있으면 seq > 커서 최대 PAGE_LIMIT. 없으면 최근 창. 창 모드는 max(seq)를 먼저 읽고 그 이하만 읽어
    # 두 쿼리 사이에 들어온 주문이 last_seq 아래로 빠지지 않게 한다.
    def orders_page(cursor, market)
      scope = Order.joins(:account, :asset)
      if cursor
        rows = scope.where("orders.seq > ?", cursor).order("orders.seq").limit(PAGE_LIMIT).pluck(*ORDER_COLUMNS)
        return [rows.map { |r| order_row(r) }, rows.empty? ? cursor : rows.last.first]
      end

      top = Order.maximum(:seq) || 0
      rows = market ? window_rows(scope.where("orders.seq <= ? AND orders.accepted_at >= ?", top, market - WINDOW_SECONDS),
                                  "orders.seq", ORDER_COLUMNS) : []
      [rows.map { |r| order_row(r) }, top]
    end

    def executions_page(cursor, market, day)
      scope = Execution.joins(:asset).joins(AUCTION_JOIN)
      if cursor
        rows = scope.where("executions.id > ?", cursor).order("executions.id").limit(PAGE_LIMIT).pluck(*EXEC_COLUMNS)
        return [rows.map { |r| exec_row(r) }, rows.empty? ? cursor : rows.last.first]
      end

      top = Execution.maximum(:id) || 0
      rows = if market && day
               window_rows(scope.where("executions.id <= ? AND executions.trade_date = ? AND executions.executed_at >= ?",
                                       top, day, market - WINDOW_SECONDS), "executions.id", EXEC_COLUMNS)
             else
               []
             end
      [rows.map { |r| exec_row(r) }, top]
    end

    # 최신 PAGE_LIMIT 건을 오래된 순으로.
    def window_rows(scope, key, columns)
      scope.order("#{key} DESC").limit(PAGE_LIMIT).pluck(*columns).reverse
    end

    def order_row(row)
      seq, asset, account, side, type, price, qty, status, reason, at = row
      { seq: seq, asset: asset, side: side, order_type: type, price: price, qty: qty, status: status,
        reject_reason: reason, accepted_at: iso(at), house: house_of(account) }
    end

    def exec_row(row)
      id, asset, price, qty, at, session = row
      { id: id, asset: asset, price: price, qty: qty, executed_at: iso(at), session: session || "continuous" }
    end

    # VINV-001..005 → 0, 006..010 → 1. 투자자 코드가 아니면 nil.
    def house_of(code)
      number = code[/\AVINV-(\d+)\z/, 1]&.to_i
      number && number >= 1 ? (number - 1) / HOUSE_SIZE : nil
    end

    # --- settlements · reconcile ---------------------------------------------

    def settlements
      entries = Arel.sql("(SELECT COUNT(*) FROM ledger_entries WHERE ledger_entries.settlement_id = settlements.id)")
      rows = Settlement.order(settle_date: :desc).limit(SETTLEMENT_COUNT).pluck(:settle_date, :status, :settled_at, entries)
      rows.map do |date, status, at, count|
        { settle_date: date.iso8601, status: status, settled_at: at && iso(at), entries: count.to_i }
      end
    end

    def reconcile_count(day)
      return nil unless day

      @cache.fetch("securities:street:reconcile:#{day.iso8601}", expires_in: RECONCILE_TTL,
                                                                  race_condition_ttl: RECONCILE_RACE_TTL) do
        Reconcile.call(as_of: day).size
      end
    end
  end
end
