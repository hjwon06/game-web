require "test_helper"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# 시가 단일가(Auction.open!) · 끄기 스위치 · 접속매매 시작 문. 기준가 50,000 → 가격제한 [35,000, 65,000].
# 달력은 11-02(월) ~ 11-06(금) 영업이라 11-02 체결의 결제일은 11-04 다. 장전 접수(08:40)는 체결 없이 남는다.
# 변이 검사: 시작 문(PlaceOrder#opened?)을 빼면 T2 첫 단언이, 행 확인(멱등)을 빼면 T2 의 두 번째 open! 이 실패해야 한다.
class Securities::AuctionTest < ActiveSupport::TestCase
  KST = ActiveSupport::TimeZone["Asia/Seoul"]
  DAY = Date.new(2026, 11, 2)

  setup do
    @cash = Securities::Asset.create!(code: "VKRW", name: "가상원화", kind: "cash")
    @equity = Securities::Asset.create!(code: "VT-EQ", name: "가상종목", kind: "equity", base_price: 50_000)
    (2..6).each { |d| Securities::MarketDay.create!(trade_date: Date.new(2026, 11, d), business_day: true) }
    @pre_open = KST.local(2026, 11, 2, 8, 40, 0)
    @nine = KST.local(2026, 11, 2, 9, 0, 0)
    @ten = KST.local(2026, 11, 2, 10, 0, 0)
    @n = 0
  end

  def place(side, qty:, price: nil, at: @pre_open, cash: 10_000_000)
    place_on(@equity, side, qty: qty, price: price, at: at, cash: cash)
  end

  def place_on(asset, side, qty:, price: nil, at: @pre_open, cash: 10_000_000)
    account = Securities::Account.create!(code: "VT-#{@n += 1}", name: "가상투자자", kind: "investor")
    if side == "buy"
      Securities::Position.create!(account: account, asset: @cash, qty: cash)
    else
      Securities::Position.create!(account: account, asset: asset, qty: 100)
    end
    Securities::PlaceOrder.call(account: account, asset: asset, side: side, order_type: price ? "limit" : "market",
                                qty: qty, price: price, client_key: "k-#{@n}", at: at)
  end

  # T1 의 첫 책. 매수 → 매도 순으로 접수해 seq 가 매수 < 매도 다.
  def t1_book
    buys = [[3, 51_000], [2, 50_500], [5, 50_000]].map { |qty, price| place("buy", qty: qty, price: price) }
    sells = [[4, 49_500], [3, 50_000], [5, 50_500]].map { |qty, price| place("sell", qty: qty, price: price) }
    [buys, sells]
  end

  def open!(**opts)
    Securities::Auction.open!(asset: @equity, trade_date: DAY, at: @nine, **opts)
  end

  test "T1 시가 단일가: 50,000 에 7주, 체결가는 전부 50,000 이고 매수는 높은 값부터 · 매도는 낮은 값부터 채워진다" do
    buys, sells = t1_book

    auction = open!

    assert_equal ["single", 50_000, 7, DAY, "open"], [auction.mode, auction.price, auction.qty, auction.trade_date, auction.session]
    executions = Securities::Execution.order(:id).to_a
    assert_equal [50_000] * executions.size, executions.map(&:price)
    assert_equal 7, executions.sum(&:qty)
    assert_equal [[3, "filled"], [2, "filled"], [2, "partially_filled"]], buys.map { |o| o.reload.then { [_1.filled_qty, _1.status] } }
    assert_equal [[4, "filled"], [3, "filled"], [0, "accepted"]], sells.map { |o| o.reload.then { [_1.filled_qty, _1.status] } }
    assert_equal [0, @nine], [buys[0].hold.qty, buys[0].hold.released_at] # 51,000 으로 잡은 홀드가 50,000 체결 뒤 전부 풀렸다
    assert_equal [150_000, nil], [buys[2].hold.qty, buys[2].hold.released_at] # 단가 50,000 × 남은 3
    assert_equal [@nine, Date.new(2026, 11, 4)], [executions.first.executed_at, executions.first.settle_date]
  end

  test "T2 시작 문: open! 전에는 10:00 에 맞는 주문이 와도 체결이 없고, open! 뒤에 체결된다" do
    sell = place("sell", qty: 1, price: 50_000, at: @ten)
    buy = place("buy", qty: 1, price: 50_000, at: @ten)

    assert_equal %w[accepted accepted], [sell.status, buy.status]
    assert_equal 0, Securities::Execution.count
    assert_equal 0, Securities::Auction.count

    open!

    assert_equal %w[filled filled], [sell.reload.status, buy.reload.status]
    assert_equal [50_000, 1], Securities::Execution.sole.then { |e| [e.price, e.qty] }
  end

  test "T2 멱등: open! 을 두 번 돌려도 행 1 · 체결 그대로" do
    place("buy", qty: 2, price: 50_000)
    place("sell", qty: 2, price: 50_000)

    first = open!
    executions = Securities::Execution.pluck(:id, :qty, :price)
    second = open!(single_price: false) # 두 번째 호출이 다른 모드를 요구해도 이미 있는 행이 그대로 돌아온다

    assert_equal first.id, second.id
    assert_equal "single", second.mode
    assert_equal 1, Securities::Auction.count
    assert_equal executions, Securities::Execution.pluck(:id, :qty, :price)
    assert_equal [[2, 50_000]], executions.map { |_, qty, price| [qty, price] }
  end

  test "open! 뒤 접수는 접속매매로 바로 체결된다(시작 문이 열린다)" do
    open!
    sell = place("sell", qty: 1, price: 50_000, at: @ten)
    buy = place("buy", qty: 1, price: 50_000, at: @ten + 60)

    assert_equal %w[filled filled], [sell.reload.status, buy.reload.status]
    assert_equal 1, Securities::Execution.count
  end

  test "T2 시장가: 단일가 가격에 먼저 체결되고 남은 건 cancelled · 홀드 해제" do
    place("sell", qty: 2, price: 50_000)
    market = place("buy", qty: 5, cash: 1_000_000)
    assert_equal "accepted", market.status
    assert_nil market.price

    auction = open!

    assert_equal [50_000, 2], [auction.price, auction.qty]
    assert_equal ["cancelled", 2], [market.reload.status, market.filled_qty]
    assert_equal [195_000, @nine], [market.hold.qty, market.hold.released_at] # 상한가 65,000 × 남은 3 이 풀린다
    assert_equal 900_000, Securities::Available.for(market.account, @cash) # 체결 100,000 만 나간 것으로 센다
  end

  test "체결이 없으면 행은 price NULL · qty 0 이고 지정가는 그대로 남는다" do
    buy = place("buy", qty: 1, price: 49_000)
    place("sell", qty: 1, price: 51_000)

    auction = open!

    assert_equal ["single", nil, 0], [auction.mode, auction.price, auction.qty]
    assert_equal 0, Securities::Execution.count
    assert_equal "accepted", buy.reload.status
  end

  test "T3 끄기: single_price false 면 장전 접수분을 seq 순으로 Match 체결하고 mode 는 sequential 이다" do
    buys, sells = t1_book

    auction = open!(single_price: false)

    assert_equal ["sequential", nil, 7], [auction.mode, auction.price, auction.qty]
    executions = Securities::Execution.order(:id).to_a
    # 먼저 있던(seq 가 작은) 매수 가격으로 체결된다. 단일가였다면 전부 50,000 이다.
    assert_equal [[buys[0].id, sells[0].id, 51_000, 3], [buys[1].id, sells[0].id, 50_500, 1],
                  [buys[1].id, sells[1].id, 50_500, 1], [buys[2].id, sells[1].id, 50_000, 2]],
                 executions.map { |e| [e.buy_order_id, e.sell_order_id, e.price, e.qty] }
    assert_equal 7, executions.sum(&:qty)
  end

  # minitest 6 에는 Object#stub 이 없다(minitest/mock 분리). single_price_default 를 armed 동안만 덮는다.
  module SinglePriceOverride
    def single_price_default
      SinglePriceOverride.armed ? SinglePriceOverride.value : super
    end

    class << self
      attr_accessor :armed, :value
    end
  end
  Securities::AuctionRun.singleton_class.prepend(SinglePriceOverride)

  test "끄기 스위치는 config/securities_clock.yml 에서 읽힌다: 켜져 있으면 single, 설정을 false 로 돌리면 sequential" do
    place("buy", qty: 1, price: 50_000)
    place("sell", qty: 1, price: 50_000)
    assert_equal true, Securities::AuctionRun.single_price_default # 덮기 전: 설정 파일 값

    assert_equal "single", open!.mode

    other = Securities::Asset.create!(code: "VT-EQ2", name: "다른종목", kind: "equity", base_price: 50_000)
    SinglePriceOverride.value = false
    SinglePriceOverride.armed = true
    assert_equal "sequential", Securities::Auction.open!(asset: other, trade_date: DAY, at: @nine).mode
  ensure
    SinglePriceOverride.armed = false
  end

  test "T1 충실도: 끄기면 들어온 순서대로 만난다 — 매수는 먼저 온 49,000 매도와 50,000 에 체결되고 뒤에 온 48,000 은 남는다" do
    buy = place("buy", qty: 1, price: 50_000)
    sell_a = place("sell", qty: 1, price: 49_000)
    sell_b = place("sell", qty: 1, price: 48_000)

    auction = open!(single_price: false)

    assert_equal ["sequential", 1], [auction.mode, auction.qty]
    execution = Securities::Execution.sole
    assert_equal [buy.id, sell_a.id, 50_000, 1], [execution.buy_order_id, execution.sell_order_id, execution.price, execution.qty]
    assert_equal %w[filled filled accepted], [buy, sell_a, sell_b].map { |o| o.reload.status }
  end

  test "T2 끄기 + 시장가: 먼저 들어온 상대가 없는 시장가는 체결 없이 cancelled · 홀드 해제, 켜기면 단일가 50,000 에 1주" do
    market = place("buy", qty: 1)
    sell = place("sell", qty: 1, price: 50_000)

    auction = open!(single_price: false)

    assert_equal ["sequential", 0], [auction.mode, auction.qty]
    assert_equal 0, Securities::Execution.count
    assert_equal ["cancelled", 0, @nine], [market.reload.status, market.filled_qty, market.hold.released_at]
    assert_equal "accepted", sell.reload.status

    other = Securities::Asset.create!(code: "VT-EQ2", name: "다른종목", kind: "equity", base_price: 50_000)
    market2 = place_on(other, "buy", qty: 1)
    place_on(other, "sell", qty: 1, price: 50_000)

    on = Securities::Auction.open!(asset: other, trade_date: DAY, at: @nine, single_price: true)

    assert_equal ["single", 50_000, 1], [on.mode, on.price, on.qty]
    assert_equal ["filled", 1], [market2.reload.status, market2.filled_qty]
    assert_equal 50_000, Securities::Execution.find_by!(asset_id: other.id).price
  end

  test "T3 단일가 같은 가격 안은 seq 순: 먼저 온 1주가 다 차고 뒤에 온 3주는 1주만 찬다" do
    small = place("buy", qty: 1, price: 50_000)
    large = place("buy", qty: 3, price: 50_000)
    place("sell", qty: 2, price: 50_000)

    auction = open!

    assert_equal ["single", 50_000, 2], [auction.mode, auction.price, auction.qty]
    assert_equal [[1, "filled"], [1, "partially_filled"]], [small, large].map { |o| o.reload.then { [_1.filled_qty, _1.status] } }
  end
end
