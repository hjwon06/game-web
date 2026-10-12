require "test_helper"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# 접수 규칙. PlaceOrder 가 Phase · Tick · Available 을 실제로 부르는지는 각 거절이 그 모듈의 판정에서만
# 나올 수 있게 입력을 골라 확인한다(토요일 → closed, 호가 위반 → tick, 현금 부족 → insufficient).
class Securities::PlaceOrderTest < ActiveSupport::TestCase
  KST = ActiveSupport::TimeZone["Asia/Seoul"]

  setup do
    @cash = Securities::Asset.create!(code: "VKRW", name: "가상원화", kind: "cash")
    @equity = Securities::Asset.create!(code: "VT-EQ", name: "가상종목", kind: "equity", base_price: 50_000)
    @me = Securities::Account.create!(code: "VT-ME", name: "가상투자자", kind: "investor")
    Securities::Position.create!(account: @me, asset: @cash, qty: 1_000_000)
    Securities::Position.create!(account: @me, asset: @equity, qty: 10)
    Securities::MarketDay.create!(trade_date: Date.new(2026, 11, 2), business_day: true) # 월
    Securities::MarketDay.create!(trade_date: Date.new(2026, 11, 7), business_day: false) # 토
    @open = KST.local(2026, 11, 2, 10, 0, 0)
    @n = 0
  end

  def place(side: "buy", order_type: "limit", qty: 1, price: 50_000, key: nil, at: @open, account: @me, asset: @equity)
    price = nil if order_type == "market"
    Securities::PlaceOrder.call(account: account, asset: asset, side: side, order_type: order_type, qty: qty,
                                price: price, client_key: key || "k-#{@n += 1}", at: at)
  end

  def assert_rejected(order, reason)
    assert_equal "rejected", order.status
    assert_equal reason, order.reject_reason
    assert_nil order.hold, "거절 주문은 홀드가 없다"
  end

  test "매수 지정가 접수: 주문 1 + 현금 홀드 가격 × 수량" do
    order = place(qty: 4, price: 50_000)

    assert_equal "accepted", order.status
    assert_nil order.reject_reason
    assert_equal @open, order.accepted_at
    assert_equal [@cash.id, 200_000, nil], [order.hold.asset_id, order.hold.qty, order.hold.released_at]
    assert_equal 800_000, Securities::Available.for(@me, @cash)
  end

  test "매수 시장가는 상한가 × 수량을 현금 홀드로 잡는다" do
    order = place(order_type: "market", qty: 2)

    assert_nil order.price
    assert_equal 130_000, order.hold.qty # 상한가 65,000 × 2
    assert_equal @cash.id, order.hold.asset_id
  end

  test "매도는 종목 수량을 홀드한다" do
    order = place(side: "sell", qty: 4)

    assert_equal [@equity.id, 4], [order.hold.asset_id, order.hold.qty]
    assert_equal 6, Securities::Available.for(@me, @equity)
  end

  test "장 밖(토요일 휴장 · 08:29:59 · 15:30)은 closed 로 거절하고 사전 · 종가 단계는 접수한다" do
    saturday = KST.local(2026, 11, 7, 10, 0, 0)

    assert_rejected place(at: saturday), "closed"
    assert_rejected place(at: KST.local(2026, 11, 2, 8, 29, 59)), "closed"
    assert_rejected place(at: KST.local(2026, 11, 2, 15, 30, 0)), "closed"
    assert_equal "accepted", place(at: KST.local(2026, 11, 2, 8, 30, 0)).status
    assert_equal "accepted", place(at: KST.local(2026, 11, 2, 15, 29, 59)).status
  end

  test "closed 가 tick · price_limit · insufficient 보다 먼저다" do
    saturday = KST.local(2026, 11, 7, 10, 0, 0)

    assert_rejected place(at: saturday, price: 50_050, qty: 1_000), "closed"
  end

  test "호가 단위 위반(50,050)은 tick 이다" do
    assert_rejected place(price: 50_050), "tick"
  end

  test "가격제한: 기준가 50,000 에서 65,000 접수 · 65,100 · 34,950 거절 · 35,000 접수" do
    assert_equal "accepted", place(price: 65_000).status
    assert_rejected place(price: 65_100), "price_limit"
    assert_rejected place(price: 34_950), "price_limit"
    assert_equal "accepted", place(price: 35_000).status
  end

  test "매수 현금 부족은 insufficient 이고 열린 홀드를 이미 차감한 값으로 본다" do
    assert_equal "accepted", place(qty: 12, price: 50_000).status # 600,000
    assert_rejected place(qty: 9, price: 50_000), "insufficient"  # 450,000 > 400,000
    assert_equal "accepted", place(qty: 8, price: 50_000).status  # 400,000 = 남은 전부
    assert_rejected place(qty: 1, price: 35_000), "insufficient"
  end

  test "매도 수량 부족은 insufficient 이다" do
    assert_rejected place(side: "sell", qty: 11), "insufficient"
    assert_equal "accepted", place(side: "sell", qty: 6).status
    assert_rejected place(side: "sell", qty: 5), "insufficient"
  end

  test "거절 주문도 행으로 남고 reject_reason 은 rejected 에만 있다" do
    accepted = place
    rejected = place(price: 50_050)

    assert_equal [accepted.id, rejected.id].sort, Securities::Order.where(account_id: @me.id).pluck(:id).sort
    assert_equal [nil], Securities::Order.where(status: "accepted").pluck(:reject_reason).uniq
    assert_equal ["tick"], Securities::Order.where.not(reject_reason: nil).pluck(:reject_reason)
  end

  test "같은 키 · 같은 내용은 기존 주문을 돌려주고 행이 늘지 않는다(거절도 같다)" do
    first = place(key: "dup", qty: 2)
    again = place(key: "dup", qty: 2)
    rejected = place(key: "dup-bad", price: 50_050)
    rejected_again = place(key: "dup-bad", price: 50_050)

    assert_equal first.id, again.id
    assert_equal rejected.id, rejected_again.id
    assert_equal 2, Securities::Order.count
    assert_equal 1, Securities::Hold.count
  end

  test "같은 키 · 다른 내용은 Conflict 이고 기존 주문은 그대로다" do
    first = place(key: "dup", qty: 2)

    [{ qty: 3 }, { price: 50_100 }, { side: "sell" }, { order_type: "market" }].each do |change|
      args = { key: "dup", qty: 2 }.merge(change)
      assert_raises(Securities::PlaceOrder::Conflict) { place(**args) }
    end
    assert_equal [first.id], Securities::Order.pluck(:id)
    assert_equal 2, first.reload.qty
    assert_equal 100_000, Securities::Hold.sole.qty
  end

  test "투자자 계좌와 종목이 아니면 ArgumentError 이고 행이 없다" do
    broker = Securities::Account.create!(code: "VT-BRK", name: "가상증권사", kind: "broker")

    assert_raises(ArgumentError) { place(account: broker) }
    assert_raises(ArgumentError) { place(asset: @cash) }
    assert_raises(ArgumentError) { place(qty: 0) }
    assert_raises(ArgumentError) { place(side: "hold") }
    assert_raises(ArgumentError) { Securities::PlaceOrder.call(account: @me, asset: @equity, side: "buy", order_type: "limit",
                                                               qty: 1, price: nil, client_key: "np", at: @open) }
    assert_equal 0, Securities::Order.count
    assert_equal 0, Securities::Hold.count
  end
end
