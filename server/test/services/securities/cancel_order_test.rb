require "test_helper"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# 취소: accepted · partially_filled 만 cancelled 가 되고 홀드가 풀려 가능 수량이 돌아온다.
class Securities::CancelOrderTest < ActiveSupport::TestCase
  KST = ActiveSupport::TimeZone["Asia/Seoul"]

  setup do
    @cash = Securities::Asset.create!(code: "VKRW", name: "가상원화", kind: "cash")
    @equity = Securities::Asset.create!(code: "VT-EQ", name: "가상종목", kind: "equity", base_price: 50_000)
    @me = Securities::Account.create!(code: "VT-ME", name: "가상투자자", kind: "investor")
    Securities::Position.create!(account: @me, asset: @cash, qty: 1_000_000)
    Securities::Position.create!(account: @me, asset: @equity, qty: 10)
    Securities::MarketDay.create!(trade_date: Date.new(2026, 11, 2), business_day: true)
    # 사전(pre_open) 접수는 체결이 없다. 10:00 이면 같은 계좌의 매수 · 매도 50,000 이 서로 체결돼 이 테스트의 전제가 깨진다.
    @open = KST.local(2026, 11, 2, 8, 40, 0)
    @later = KST.local(2026, 11, 2, 11, 0, 0)
    # 시작 문(D7): 그날 시가 행이 있어야 10:00 접수가 Match 를 부른다. 실제 체결 테스트의 전제다.
    Securities::Auction.create!(asset: @equity, trade_date: Date.new(2026, 11, 2), session: "open", mode: "sequential",
                                qty: 0, ran_at: @open)
  end

  def place(side: "buy", qty: 4, price: 50_000, key: SecureRandom.uuid)
    Securities::PlaceOrder.call(account: @me, asset: @equity, side: side, order_type: "limit", qty: qty,
                                price: price, client_key: key, at: @open)
  end

  def cancel(order)
    Securities::CancelOrder.call(order: order, at: @later)
  end

  test "취소하면 홀드가 풀리고 가능 수량이 돌아온다(현금 · 종목)" do
    buy = place(qty: 4)
    sell = place(side: "sell", qty: 6)
    assert_equal 800_000, Securities::Available.for(@me, @cash)
    assert_equal 4, Securities::Available.for(@me, @equity)

    cancel(buy)
    cancel(sell)

    assert_equal 1_000_000, Securities::Available.for(@me, @cash)
    assert_equal 10, Securities::Available.for(@me, @equity)
    assert_equal "cancelled", buy.reload.status
    assert_equal @later, buy.hold.released_at
  end

  test "부분 체결 주문도 취소된다" do
    order = place
    order.update!(status: "partially_filled", filled_qty: 1)

    assert_equal "cancelled", cancel(order).status
    assert_equal @later, order.hold.reload.released_at
  end

  test "끝난 주문(filled · cancelled · rejected)은 그대로 돌려주고 아무것도 바뀌지 않는다" do
    filled = place(key: "f")
    filled.update!(status: "filled", filled_qty: filled.qty)
    done = place(key: "c")
    cancel(done)
    rejected = place(key: "r", price: 50_050)
    before = Securities::Hold.order(:id).pluck(:id, :qty, :released_at)

    assert_equal "filled", cancel(filled).status
    assert_equal "cancelled", cancel(done).status
    assert_equal "rejected", cancel(rejected).status
    assert_equal before, Securities::Hold.order(:id).pluck(:id, :qty, :released_at)
    assert_equal @later, done.hold.reload.released_at # 두 번째 취소가 시각을 덮어쓰지 않는다
  end

  test "실제 체결로 부분 체결된 메이커를 취소하면 남은 홀드만 풀리고 체결분은 그대로다" do
    [Date.new(2026, 11, 3), Date.new(2026, 11, 4)].each { |d| Securities::MarketDay.create!(trade_date: d, business_day: true) }
    buyer = Securities::Account.create!(code: "VT-BUY", name: "가상매수자", kind: "investor")
    Securities::Position.create!(account: buyer, asset: @cash, qty: 1_000_000)
    maker = place(side: "sell", qty: 4)
    Securities::PlaceOrder.call(account: buyer, asset: @equity, side: "buy", order_type: "limit", qty: 1,
                                price: 50_000, client_key: "t", at: KST.local(2026, 11, 2, 10, 0, 0))
    assert_equal ["partially_filled", 1], maker.reload.then { |o| [o.status, o.filled_qty] }

    cancelled = cancel(maker)

    assert_equal ["cancelled", 1], [cancelled.status, cancelled.filled_qty]
    assert_equal @later, maker.hold.reload.released_at
    assert_equal 9, Securities::Available.for(@me, @equity) # 10 − 미결제 매도 체결 1
    assert_equal 1, Securities::Execution.count
  end

  test "낡은 order 객체(status accepted)로 불러도 DB 의 현재 상태를 따른다" do
    stale = place
    Securities::Order.where(id: stale.id).update_all(status: "filled", filled_qty: stale.qty)

    assert_equal "filled", cancel(stale).status
    assert_nil stale.hold.reload.released_at
  end
end
