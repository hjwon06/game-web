# 접속매매 체결. 시뮬레이터 규칙이다(거래소 원문은 확인하지 않았다).
# 들어온 주문(taker)이 같은 종목 반대편 accepted · partially_filled 지정가 잔량(maker)과 만난다.
#   - 우선순위: 가격(매수가 들어오면 싼 매도부터, 매도가 들어오면 비싼 매수부터) → seq(접수 순서).
#     수량 우선은 seq 가 유일해 여기서는 쓰이지 않는다(④ 몫).
#   - 들어온 주문이 지정가면 가격이 맞는 것까지만. 시장가는 가격 조건이 없다.
#   - 체결가 = 먼저 있던 주문 가격, 수량 = 양쪽 잔량 중 작은 값.
#   - 체결 기록(Execution · filled_qty · status · 홀드 차감)은 Securities::Fill 이 한다. 단일가(AuctionRun)와 같이 쓴다.
#     홀드: 매도는 체결 수량만큼, 매수는 "홀드 단가 × 체결 수량"만큼 줄어든다(자세한 규칙은 fill.rb).
#   - 메이커 계좌는 잠그지 않는다: 메이커는 자기 가격에 체결되어 가능 수량이 변하지 않는다.
#   - 들어온 시장가 주문의 잔량은 매칭 직후 cancelled + 홀드 해제다.
# 잠금 순서(모든 경로 공통): 주문 키 advisory → 계좌 FOR UPDATE → 책 잠금 → 주문 행.
# 책 잠금은 pg_advisory_xact_lock(int, int) 형태라 주문 키의 bigint 1개 형태와 키 공간이 겹치지 않는다.
# 종목 행 FOR UPDATE 는 쓰지 않는다 — orders · executions INSERT 의 FK 가 종목 행에 KEY SHARE 를 잡아 두 트랜잭션이 서로 막는다.
module Securities
  class Match
    BOOK_NS = 7_301_003 # int4 범위. 책 잠금 전용 네임스페이스.
    BATCH = 50

    # before_seq: 주어지면 반대편 후보를 seq 가 그보다 작은 주문으로 거른다(끄기 스위치의 "들어온 순서대로").
    # 기본값 nil 은 거르지 않는다 — 접속매매(PlaceOrder)는 넘기지 않는다.
    def self.call(order:, at:, before_seq: nil)
      new(order: order, at: at, before_seq: before_seq).call
    end

    # 종목 1개의 호가 책 잠금. 트랜잭션이 끝나면 풀린다. CancelOrder 도 같은 잠금을 쓴다(순서 정의는 이 파일 머리말).
    def self.lock_book(asset_id)
      sql = Record.sanitize_sql(["SELECT pg_advisory_xact_lock(?, ?)", BOOK_NS, Integer(asset_id)])
      Record.lease_connection.execute(sql)
    end

    def initialize(order:, at:, before_seq: nil)
      @order = order
      @at = at
      @before_seq = before_seq
    end

    # 체결 반영 뒤 다시 읽은 주문을 돌려준다.
    def call
      Record.transaction do
        self.class.lock_book(@order.asset_id)
        taker = Order.lock.find(@order.id) # 책 잠금 뒤 주문 행. 호출자의 객체는 낡았을 수 있다.
        if Order::CANCELLABLE.include?(taker.status)
          fill_against_book(taker)
          close_market_remainder(taker)
        end
        taker
      end
    end

    private

    def fill_against_book(taker)
      taker_hold = Hold.find_by!(order_id: taker.id)
      while taker.qty > taker.filled_qty
        makers = candidates(taker).limit(BATCH).to_a
        break if makers.empty?

        holds = Hold.where(order_id: makers.map(&:id)).index_by(&:order_id)
        makers.each do |maker|
          break if taker.qty == taker.filled_qty

          execute(taker, taker_hold, maker, holds.fetch(maker.id))
        end
      end
    end

    # 책 잠금을 쥔 채 FOR UPDATE 로 읽는다. 취소는 같은 책 잠금 뒤에야 주문 행에 닿으므로 대기하지 않는다.
    def candidates(taker)
      buy = taker.side == "buy"
      scope = Order.where(asset_id: taker.asset_id, side: buy ? "sell" : "buy", order_type: "limit",
                          status: Order::CANCELLABLE).where("qty > filled_qty")
      scope = scope.where(buy ? "price <= ?" : "price >= ?", taker.price) if taker.order_type == "limit"
      scope = scope.where("seq < ?", @before_seq) if @before_seq
      scope.order(price: buy ? :asc : :desc, seq: :asc).lock
    end

    def execute(taker, taker_hold, maker, maker_hold)
      qty = [taker.qty - taker.filled_qty, maker.qty - maker.filled_qty].min
      buy, sell = taker.side == "buy" ? [taker, maker] : [maker, taker]
      buy_hold, sell_hold = taker.side == "buy" ? [taker_hold, maker_hold] : [maker_hold, taker_hold]
      Fill.call(buy: buy, sell: sell, buy_hold: buy_hold, sell_hold: sell_hold, price: price_for(taker, maker),
                qty: qty, at: @at, trade_date: trade_date, settle_date: settle_date)
    end

    # 먼저 있던(seq 가 작은) 주문의 가격. 시장가는 가격이 없으므로 항상 지정가 쪽이다.
    def price_for(taker, maker)
      taker.price && taker.seq < maker.seq ? taker.price : maker.price
    end

    def close_market_remainder(taker)
      return unless taker.order_type == "market" && taker.qty > taker.filled_qty

      taker.update!(status: "cancelled")
      Hold.where(order_id: taker.id, released_at: nil).update_all(released_at: @at)
    end

    def trade_date
      @trade_date ||= @at.in_time_zone(Phase::ZONE).to_date
    end

    # 체결이 실제로 날 때만 달력을 읽는다(달력이 모자라면 예외 → 트랜잭션 전체가 되돌아간다).
    def settle_date
      @settle_date ||= Calendar.settle_date(trade_date)
    end
  end
end
