# 체결 1건 기록. 접속매매(Match)와 단일가(AuctionRun)가 같이 쓴다. 시뮬레이터 규칙이다.
#   - executions 행 1 + 양쪽 주문의 filled_qty · status + 양쪽 홀드 차감(0 이 되면 released_at).
#   - 홀드: 매도는 체결 수량만큼, 매수는 "홀드 단가 × 체결 수량"만큼 줄어든다. 홀드 단가는 체결 전
#     hold.qty ÷ 남은 수량이라 싸게 체결된 차액이 체결 즉시 풀린다.
# 잠금은 잡지 않는다. 호출자가 책 잠금 안에서 두 주문 행을 FOR UPDATE 로 읽어 넘긴다(순서는 match.rb 머리말).
# 거래일 · 결제일 계산은 호출자 몫이다(체결이 실제로 날 때만 달력을 읽게 하려고 값으로 받는다).
module Securities
  module Fill
    module_function

    def call(buy:, sell:, buy_hold:, sell_hold:, price:, qty:, at:, trade_date:, settle_date:)
      Execution.create!(asset_id: buy.asset_id, buy_order: buy, sell_order: sell, price: price, qty: qty,
                        executed_at: at, trade_date: trade_date, settle_date: settle_date)
      apply(buy, buy_hold, qty, at)
      apply(sell, sell_hold, qty, at)
    end

    def apply(order, hold, qty, at)
      spent = order.side == "sell" ? qty : hold_unit(hold, order.qty - order.filled_qty) * qty
      filled = order.filled_qty + qty
      order.update!(filled_qty: filled, status: filled == order.qty ? "filled" : "partially_filled")

      left = hold.qty - spent
      hold.update!(left.zero? ? { qty: left, released_at: at } : { qty: left })
    end

    def hold_unit(hold, remaining)
      unit, rest = hold.qty.divmod(remaining)
      raise "홀드 #{hold.id} 의 qty #{hold.qty} 가 남은 수량 #{remaining} 으로 나누어떨어지지 않는다" unless rest.zero?

      unit
    end
  end
end
