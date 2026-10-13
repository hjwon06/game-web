require "test_helper"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# 체결 1건 기록(Fill). Match · AuctionRun 이 같이 쓰는 모듈이라 여기서는 직접 불러 기록 규칙만 본다.
# 주문은 pre_open(08:40)에 접수해 체결 없이 남긴다. 기준가 50,000, 달력은 11-02(월) ~ 11-06(금).
class Securities::FillTest < ActiveSupport::TestCase
  KST = ActiveSupport::TimeZone["Asia/Seoul"]

  setup do
    @cash = Securities::Asset.create!(code: "VKRW", name: "가상원화", kind: "cash")
    @equity = Securities::Asset.create!(code: "VT-EQ", name: "가상종목", kind: "equity", base_price: 50_000)
    (2..6).each { |d| Securities::MarketDay.create!(trade_date: Date.new(2026, 11, d), business_day: true) }
    @buyer = Securities::Account.create!(code: "VT-B", name: "가상매수자", kind: "investor")
    @seller = Securities::Account.create!(code: "VT-S", name: "가상매도자", kind: "investor")
    Securities::Position.create!(account: @buyer, asset: @cash, qty: 10_000_000)
    Securities::Position.create!(account: @seller, asset: @equity, qty: 100)
    @pre_open = KST.local(2026, 11, 2, 8, 40, 0)
    @at = KST.local(2026, 11, 2, 9, 0, 0)
  end

  def place(account, side, qty:, price:)
    Securities::PlaceOrder.call(account: account, asset: @equity, side: side, order_type: "limit", qty: qty,
                                price: price, client_key: "k-#{SecureRandom.hex(4)}", at: @pre_open)
  end

  def fill(buy, sell, qty:, price:)
    Securities::Fill.call(buy: buy, sell: sell, buy_hold: buy.hold, sell_hold: sell.hold, price: price, qty: qty,
                          at: @at, trade_date: Date.new(2026, 11, 2), settle_date: Date.new(2026, 11, 4))
  end

  test "체결 1건: Execution 1 · 양쪽 filled_qty · status · 홀드 차감(매수는 홀드 단가 × 수량)" do
    buy = place(@buyer, "buy", qty: 3, price: 51_000) # 홀드 153,000 = 단가 51,000 × 3
    sell = place(@seller, "sell", qty: 3, price: 50_000)

    fill(buy, sell, qty: 2, price: 50_000)

    execution = Securities::Execution.sole
    assert_equal [@equity.id, buy.id, sell.id, 50_000, 2], execution.then { |e| [e.asset_id, e.buy_order_id, e.sell_order_id, e.price, e.qty] }
    assert_equal [@at, Date.new(2026, 11, 2), Date.new(2026, 11, 4)], [execution.executed_at, execution.trade_date, execution.settle_date]
    assert_equal [2, "partially_filled"], [buy.filled_qty, buy.status]
    assert_equal [2, "partially_filled"], [sell.filled_qty, sell.status]
    assert_equal [51_000, nil], [buy.hold.qty, buy.hold.released_at] # 단가 51,000 × 남은 1. 체결가로 줄였다면 52,000
    assert_equal [1, nil], [sell.hold.qty, sell.hold.released_at]
  end

  test "남은 수량을 다 채우면 filled 이고 홀드가 0 · released_at 이 찍힌다" do
    buy = place(@buyer, "buy", qty: 2, price: 50_000)
    sell = place(@seller, "sell", qty: 2, price: 50_000)

    fill(buy, sell, qty: 2, price: 50_000)

    assert_equal %w[filled filled], [buy.reload.status, sell.reload.status]
    assert_equal [0, @at], [buy.hold.reload.qty, buy.hold.released_at]
    assert_equal [0, @at], [sell.hold.reload.qty, sell.hold.released_at]
  end
end
