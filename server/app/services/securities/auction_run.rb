# 시가 · 종가 단일가 실행(Auction.open! · Auction.close! 의 본체). 시뮬레이터 규칙이다(거래소 원문은 확인하지 않았다).
#   - session 이 open 이면 시가, close 면 종가다. 가격 결정 · 체결 · 끄기는 둘이 같은 코드를 쓴다.
#   - 책 잠금 → 그 날 그 session 행이 있으면 그대로 반환(멱등) → 가격 계산 → 체결 → 행 기록. 전부 한 트랜잭션이다.
#   - single_price 가 켜져 있으면(config/securities_clock.yml) 가격 하나로 체결한다. 가격 계산은 AuctionPrice.
#     매수(시장가 → 높은 값 → seq) · 매도(시장가 → 낮은 값 → seq) 순으로 체결량만큼 Fill 한다.
#     같은 가격 안은 seq 순이다(수량 우선은 원문을 확인하지 못했다).
#   - 시장가 잔량은 cancelled 가 되고 홀드가 풀린다.
#   - 종가(close)는 거기에 더해 단일가 뒤 남은 주문을 지정가까지 전부 cancelled + 홀드 해제한다(장 마감 일괄 취소).
#     같은 책 잠금 · 같은 트랜잭션 안이라 다음 날 책은 비어서 시작한다.
#   - 꺼져 있으면 장전 접수분을 seq 순으로 Match.call(before_seq: 그 주문의 seq) 한다 — 먼저 들어온 상대하고만 만난다. 행의 mode 는 sequential, price 는 NULL, qty 는 그때 난 체결량이다.
#   - 참가자 계좌는 잠그지 않는다. 매수는 자기 값 이하, 매도는 이상으로 체결돼 가능 수량이 줄지 않는다.
# 잠금 순서는 키 → 계좌 → 책 → 주문 행 그대로고 여기서는 책 잠금부터 시작한다(계좌를 잡지 않는다).
module Securities
  class AuctionRun
    def self.call(**args)
      new(**args).call
    end

    def self.single_price_default
      value = YAML.safe_load_file(Clock::CONFIG_PATH).fetch("single_price")
      raise "single_price 는 true/false 여야 한다: #{value.inspect}" unless [true, false].include?(value)

      value
    end

    def initialize(asset:, trade_date:, at:, single_price: nil, session: "open")
      raise ArgumentError, "종목만 단일가를 돌린다" unless asset.is_a?(Asset) && asset.kind == "equity"
      raise ArgumentError, "session 은 #{Auction::SESSIONS.join('/')}" unless Auction::SESSIONS.include?(session)
      raise ArgumentError, "trade_date 는 Date" unless trade_date.is_a?(Date)

      @asset = asset
      @trade_date = trade_date
      @at = at
      @session = session
      @single = single_price.nil? ? self.class.single_price_default : single_price
    end

    def call
      Record.transaction do
        Match.lock_book(@asset.id)
        existing = Auction.find_by(asset_id: @asset.id, trade_date: @trade_date, session: @session)
        next existing if existing

        @single ? run_single : run_sequential
      end
    end

    private

    def run_single
      orders = Order.where(asset_id: @asset.id, status: Order::CANCELLABLE).where("qty > filled_qty").order(:seq).lock.to_a
      buys, sells = orders.partition { |o| o.side == "buy" }
      result = AuctionPrice.call(buys: rows(buys), sells: rows(sells), base_price: @asset.base_price)
      price, volume = result
      fill(buys, sells, price, volume) if result
      close_remainders
      Auction.create!(asset: @asset, trade_date: @trade_date, session: @session, mode: "single", price: price,
                      qty: volume || 0, ran_at: @at)
    end

    def run_sequential
      before = Execution.where(asset_id: @asset.id).maximum(:id).to_i
      rows = Order.where(asset_id: @asset.id, status: Order::CANCELLABLE).where("qty > filled_qty").order(:seq).pluck(:id, :seq)
      # 각 주문은 자기보다 먼저 들어온(seq 가 작은) 상대하고만 만난다 — 뒤에 올 주문의 더 좋은 값을 먼저 가져가지 않는다.
      rows.each { |id, seq| Match.call(order: Order.find(id), at: @at, before_seq: seq) }
      traded = Execution.where(asset_id: @asset.id).where("id > ?", before).sum(:qty)
      close_remainders # 시가는 Match 가 이미 시장가를 닫았다. 종가는 남은 지정가까지 여기서 닫는다.
      Auction.create!(asset: @asset, trade_date: @trade_date, session: @session, mode: "sequential", price: nil,
                      qty: traded, ran_at: @at)
    end

    def rows(orders)
      orders.map { |o| [o.price, o.qty - o.filled_qty] }
    end

    # 가격 우선(시장가가 맨 앞) → seq. 이 가격에 체결 가능한 주문만 추린다.
    def fill(buys, sells, price, volume)
      buys = buys.select { |o| o.price.nil? || o.price >= price }.sort_by { |o| [o.price.nil? ? 0 : 1, -(o.price || 0), o.seq] }
      sells = sells.select { |o| o.price.nil? || o.price <= price }.sort_by { |o| [o.price.nil? ? 0 : 1, o.price || 0, o.seq] }
      holds = Hold.where(order_id: (buys + sells).map(&:id)).index_by(&:order_id)
      settle_date = Calendar.settle_date(@trade_date) # 체결이 있을 때만 읽는다(달력이 모자라면 트랜잭션 전체가 되돌아간다)

      left = volume
      bi = si = 0
      while left.positive?
        buy = buys.fetch(bi)
        sell = sells.fetch(si)
        qty = [buy.qty - buy.filled_qty, sell.qty - sell.filled_qty, left].min
        Fill.call(buy: buy, sell: sell, buy_hold: holds.fetch(buy.id), sell_hold: holds.fetch(sell.id), price: price,
                  qty: qty, at: @at, trade_date: @trade_date, settle_date: settle_date)
        left -= qty
        bi += 1 if buy.filled_qty == buy.qty
        si += 1 if sell.filled_qty == sell.qty
      end
    end

    # 시가는 시장가 잔량만, 종가는 남은 주문 전부를 cancelled + 홀드 해제한다. 체결 뒤 DB 상태를 다시 읽는다.
    def close_remainders
      scope = Order.where(asset_id: @asset.id, status: Order::CANCELLABLE).where("qty > filled_qty")
      scope = scope.where(order_type: "market") if @session == "open"
      leftover = scope.lock.to_a
      return if leftover.empty?

      leftover.each { |o| o.update!(status: "cancelled") }
      Hold.where(order_id: leftover.map(&:id), released_at: nil).update_all(released_at: @at)
    end
  end
end
