require "test_helper"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# 접속매매 체결. 호가 단위: 50,000 미만 50 · 50,000 이상 200,000 미만 100. 기준가 50,000 → 가격제한 [35,000, 65,000].
# 달력은 11-02(월) ~ 11-06(금) 영업 · 주말 휴장이라 11-02 체결의 결제일은 11-04 다.
class Securities::MatchTest < ActiveSupport::TestCase
  KST = ActiveSupport::TimeZone["Asia/Seoul"]

  setup do
    @cash = Securities::Asset.create!(code: "VKRW", name: "가상원화", kind: "cash")
    @equity = Securities::Asset.create!(code: "VT-EQ", name: "가상종목", kind: "equity", base_price: 50_000)
    (2..6).each { |d| Securities::MarketDay.create!(trade_date: Date.new(2026, 11, d), business_day: true) }
    [7, 8].each { |d| Securities::MarketDay.create!(trade_date: Date.new(2026, 11, d), business_day: false) }
    @open = KST.local(2026, 11, 2, 10, 0, 0)
    @pre_open = KST.local(2026, 11, 2, 8, 40, 0)
    @n = 0
    open_day(@equity) # 시작 문(D7): 그날 시가 행이 있어야 continuous 접수가 Match 를 부른다
  end

  def open_day(asset)
    Securities::Auction.create!(asset: asset, trade_date: Date.new(2026, 11, 2), session: "open", mode: "sequential",
                                qty: 0, ran_at: @pre_open)
  end

  def investor(cash: 0, equity: 0)
    account = Securities::Account.create!(code: "VT-#{@n += 1}", name: "가상투자자", kind: "investor")
    Securities::Position.create!(account: account, asset: @cash, qty: cash) if cash.positive?
    Securities::Position.create!(account: account, asset: @equity, qty: equity) if equity.positive?
    account
  end

  def order(account, side, qty:, price: 50_000, at: @open, type: "limit")
    price = nil if type == "market"
    Securities::PlaceOrder.call(account: account, asset: @equity, side: side, order_type: type, qty: qty,
                                price: price, client_key: "k-#{@n += 1}", at: at)
  end

  def seller(qty:, price: 50_000, at: @open)
    account = investor(equity: 100)
    [account, order(account, "sell", qty: qty, price: price, at: at)]
  end

  def buyer(cash: 10_000_000)
    investor(cash: cash)
  end

  test "AC4 같은 가격 매도 a → b → c 뒤 큰 매수 1건은 a · b · c 순으로 체결되고 체결가는 매도 호가다" do
    a, b, c = Array.new(3) { seller(qty: 2).last }
    taker = order(buyer, "buy", qty: 6, price: 51_000)

    executions = Securities::Execution.order(:id).to_a
    assert_equal [a.id, b.id, c.id], executions.map(&:sell_order_id)
    assert_equal [50_000, 50_000, 50_000], executions.map(&:price) # 들어온 주문 가격 51,000 이 아니다
    assert_equal [2, 2, 2], executions.map(&:qty)
    assert_equal %w[filled filled filled filled], [a, b, c, taker].map { |o| o.reload.status }
  end

  test "더 싼 매도가 늦게 와도 먼저 체결된다(가격 우선)" do
    _, early = seller(qty: 1, price: 50_100)
    _, cheap = seller(qty: 1, price: 50_000)
    order(buyer, "buy", qty: 1, price: 50_100)

    execution = Securities::Execution.sole
    assert_equal [cheap.id, 50_000], [execution.sell_order_id, execution.price]
    assert_equal "accepted", early.reload.status
  end

  test "매도가 들어오면 가장 높은 매수부터, 같은 가격이면 먼저 온 매수부터 체결되고 체결가는 매수 호가다" do
    low = order(buyer, "buy", qty: 1, price: 50_000)
    high1 = order(buyer, "buy", qty: 1, price: 50_100)
    high2 = order(buyer, "buy", qty: 1, price: 50_100)
    order(investor(equity: 10), "sell", qty: 2, price: 50_000)

    executions = Securities::Execution.order(:id).to_a
    assert_equal [high1.id, high2.id], executions.map(&:buy_order_id)
    assert_equal [50_100, 50_100], executions.map(&:price)
    assert_equal "accepted", low.reload.status
  end

  test "부분 체결: 메이커는 partially_filled 이고 메이커의 가능 수량은 체결 전후 같다" do
    maker_account, maker = seller(qty: 5)
    equity_before = Securities::Available.for(maker_account, @equity)
    taker = order(buyer(cash: 1_000_000), "buy", qty: 2)

    assert_equal ["partially_filled", 2], maker.reload.then { |o| [o.status, o.filled_qty] }
    assert_equal equity_before, Securities::Available.for(maker_account, @equity)
    assert_equal [3, nil], [maker.hold.qty, maker.hold.released_at]
    assert_equal ["filled", 0, @open], [taker.status, taker.hold.qty, taker.hold.released_at]
    assert_equal 100_000, Securities::Available.for(maker_account, @cash) # 미결제 매도 대금이 들어올 몫으로 잡힌다
  end

  test "메이커가 매수여도 가능 수량(현금)은 체결 전후 같다" do
    maker_account = buyer(cash: 1_000_000)
    maker = order(maker_account, "buy", qty: 4, price: 50_000)
    cash_before = Securities::Available.for(maker_account, @cash)
    order(investor(equity: 10), "sell", qty: 1, price: 50_000)

    assert_equal cash_before, Securities::Available.for(maker_account, @cash)
    assert_equal [150_000, "partially_filled"], [maker.reload.hold.qty, maker.status]
  end

  test "51,000 매수가 50,000 매도와 체결되면 차액만큼 매수 가능 금액이 돌아온다" do
    account = buyer(cash: 1_000_000)
    seller(qty: 1, price: 50_000)
    taker = order(account, "buy", qty: 4, price: 51_000)

    assert_equal 153_000, taker.hold.qty # 홀드 단가 51,000 × 남은 3. 체결가로 줄였다면 154,000
    assert_equal "partially_filled", taker.status
    assert_equal 797_000, Securities::Available.for(account, @cash) # 1,000,000 − 체결 50,000 − 홀드 153,000
  end

  test "시장가 잔량은 매칭 직후 cancelled 가 되고 홀드가 풀린다(체결분은 남는다)" do
    seller(qty: 2, price: 50_000)
    account = buyer(cash: 1_000_000)
    taker = order(account, "buy", qty: 5, type: "market")

    assert_equal ["cancelled", 2], [taker.status, taker.filled_qty]
    assert_equal @open, taker.hold.released_at
    assert_equal 900_000, Securities::Available.for(account, @cash) # 체결 100,000 만 나간 것으로 센다
  end

  test "시장가인데 반대편이 비었으면 체결 없이 cancelled 이고 홀드가 풀린다" do
    account = buyer(cash: 1_000_000)
    taker = order(account, "buy", qty: 3, type: "market")

    assert_equal ["cancelled", 0], [taker.status, taker.filled_qty]
    assert_equal 1_000_000, Securities::Available.for(account, @cash)
    assert_equal 0, Securities::Execution.count
  end

  test "가격이 안 맞으면 체결하지 않는다" do
    seller(qty: 1, price: 50_000)
    taker = order(buyer, "buy", qty: 1, price: 49_500)

    assert_equal "accepted", taker.status
    assert_equal 0, Securities::Execution.count
  end

  test "pre_open · closing 접수분은 체결 없이 남는다" do
    seller(qty: 2, price: 50_000)
    pre = order(buyer, "buy", qty: 1, at: @pre_open)
    closing = order(buyer, "buy", qty: 1, at: KST.local(2026, 11, 2, 15, 25, 0))

    assert_equal %w[accepted accepted], [pre.status, closing.status]
    assert_equal 0, Securities::Execution.count
  end

  test "체결 1건: executed_at · trade_date(서울 날짜) · settle_date(영업일 +2)" do
    seller(qty: 1)
    order(buyer, "buy", qty: 1, at: KST.local(2026, 11, 2, 15, 0, 0))

    execution = Securities::Execution.sole
    assert_equal KST.local(2026, 11, 2, 15, 0, 0), execution.executed_at
    assert_equal [Date.new(2026, 11, 2), Date.new(2026, 11, 4)], [execution.trade_date, execution.settle_date]
    assert_nil execution.settlement_id
  end

  test "Match 를 직접 부르면 먼저 있던(seq 가 작은) 주문의 가격으로 체결한다" do
    resting = order(buyer, "buy", qty: 1, price: 51_000, at: @pre_open)
    incoming = order(investor(equity: 10), "sell", qty: 1, price: 50_000, at: @pre_open)
    assert_equal 0, Securities::Execution.count

    result = Securities::Match.call(order: incoming, at: @open)

    assert_equal "filled", result.status
    assert_equal [51_000, resting.id], Securities::Execution.sole.then { |e| [e.price, e.buy_order_id] }
  end

  test "다른 종목의 주문은 만나지 않는다" do
    other = Securities::Asset.create!(code: "VT-EQ2", name: "다른종목", kind: "equity", base_price: 50_000)
    open_day(other)
    account = investor(equity: 10)
    Securities::Position.create!(account: account, asset: other, qty: 10)
    Securities::PlaceOrder.call(account: account, asset: other, side: "sell", order_type: "limit", qty: 1,
                                price: 50_000, client_key: "o", at: @open)
    taker = order(buyer, "buy", qty: 1)

    assert_equal "accepted", taker.status
    assert_equal 0, Securities::Execution.count
  end
end
