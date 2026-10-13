require "test_helper"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# 종가 단일가(Auction.close!) · 장 마감 일괄 취소 · 랜덤엔드 시각. 기준가 50,000 → 가격제한 [35,000, 65,000].
# 달력은 11-02(월) ~ 11-06(금) 영업이다. 15:25 는 closing 구간이라 접수만 되고 체결은 close! 가 한다.
# 변이 검사: 일괄 취소(close_remainders)를 빼면 T1, 그날 close 행 확인을 빼면 T2 멱등,
# 끄기의 before_seq 를 빼면 T2 끄기가 실패해야 한다.
class Securities::AuctionCloseTest < ActiveSupport::TestCase
  KST = ActiveSupport::TimeZone["Asia/Seoul"]
  DAY = Date.new(2026, 11, 2)

  setup do
    @cash = Securities::Asset.create!(code: "VKRW", name: "가상원화", kind: "cash")
    @equity = Securities::Asset.create!(code: "VT-EQ", name: "가상종목", kind: "equity", base_price: 50_000)
    (2..6).each { |d| Securities::MarketDay.create!(trade_date: Date.new(2026, 11, d), business_day: true) }
    @nine = KST.local(2026, 11, 2, 9, 0, 0)
    @ten = KST.local(2026, 11, 2, 10, 0, 0)
    @closing = KST.local(2026, 11, 2, 15, 25, 0)
    @close_at = KST.local(2026, 11, 2, 15, 30, 5)
    @n = 0
  end

  def place(side, qty:, price: nil, at: @closing)
    account = Securities::Account.create!(code: "VT-#{@n += 1}", name: "가상투자자", kind: "investor")
    if side == "buy"
      Securities::Position.create!(account: account, asset: @cash, qty: 10_000_000)
    else
      Securities::Position.create!(account: account, asset: @equity, qty: 100)
    end
    Securities::PlaceOrder.call(account: account, asset: @equity, side: side, order_type: price ? "limit" : "market",
                                qty: qty, price: price, client_key: "k-#{@n}", at: at)
  end

  def close!(**opts)
    Securities::Auction.close!(asset: @equity, trade_date: DAY, at: @close_at, **opts)
  end

  def available(order)
    asset = order.side == "buy" ? @cash : @equity
    Securities::Available.for(order.account, asset)
  end

  test "T1 종가: 장중에 남은 지정가 + 15:25 접수분이 가격 하나로 체결되고 남은 주문은 전부 cancelled · 홀드 해제" do
    Securities::Auction.open!(asset: @equity, trade_date: DAY, at: @nine) # 빈 책으로 시가를 돌려 접속매매를 연다
    stay_buy = place("buy", qty: 3, price: 49_000, at: @ten) # 장중에 남은 주문. 매도 52,000 과 만나지 않는다
    stay_sell = place("sell", qty: 2, price: 52_000, at: @ten)
    market = place("buy", qty: 1)
    limit_buy = place("buy", qty: 4, price: 50_000)
    sell = place("sell", qty: 3, price: 50_000)
    assert_equal 0, Securities::Execution.count # closing 접수분은 체결 없이 남는다
    before = [stay_buy, stay_sell, market, limit_buy, sell].map { |o| available(o) }

    auction = close!

    assert_equal ["single", 50_000, 3, "close", DAY, @close_at],
                 [auction.mode, auction.price, auction.qty, auction.session, auction.trade_date, auction.ran_at]
    executions = Securities::Execution.order(:id).to_a
    assert_equal [[50_000, 1], [50_000, 2]], executions.map { |e| [e.price, e.qty] } # 시장가 1 → 지정가 2 순으로 매도 3 을 채운다
    # 시장가 1 은 전부, 지정가 4 는 2 만 찼다. 남은 2 · 장중 주문 둘 · 시장가는 모두 cancelled 다.
    statuses = [stay_buy, stay_sell, market, limit_buy, sell].map { |o| o.reload.then { [_1.status, _1.filled_qty] } }
    assert_equal [["cancelled", 0], ["cancelled", 0], ["filled", 1], ["cancelled", 2], ["filled", 3]], statuses
    assert_empty Securities::Order.where(asset_id: @equity.id, status: Securities::Order::CANCELLABLE)
    cancelled = [stay_buy, stay_sell, limit_buy]
    assert_equal [@close_at] * 3, cancelled.map { |o| o.hold.released_at }
    # 가능 수량: 안 찬 주문은 홀드만큼 돌아오고, 찬 몫은 체결 수량만큼만 나간다.
    assert_equal [before[0] + 147_000, before[1] + 2, before[3] + 100_000], # 지정가는 홀드 200,000 이 풀리고 체결 100,000 이 나간다
                 [available(stay_buy), available(stay_sell), available(limit_buy)]
    assert_equal 10_000_000, available(stay_buy)
    assert_equal 100, available(stay_sell)
    # 체결된 시장가 매수 · 매도(전량 filled)도 홀드 잔량 0, 해제 시각은 종가 시각이다.
    filled = [market, sell].map { |o| o.hold.reload }
    assert_equal [0, 0], filled.map(&:qty)
    assert_equal [@close_at] * 2, filled.map(&:released_at)
  end

  test "T2 멱등: close! 를 두 번 돌려도 close 행 1 · 체결 · 취소 시각 그대로" do
    buy = place("buy", qty: 2, price: 50_000)
    place("sell", qty: 2, price: 50_000)
    rest = place("buy", qty: 1, price: 45_000)

    first = close!
    executions = Securities::Execution.pluck(:id, :qty, :price)
    released = rest.reload.hold.released_at
    second = Securities::Auction.close!(asset: @equity, trade_date: DAY, at: @close_at + 60, single_price: false)

    assert_equal first.id, second.id
    assert_equal ["single", "close"], [second.mode, second.session]
    assert_equal 1, Securities::Auction.where(session: "close").count
    assert_equal executions, Securities::Execution.pluck(:id, :qty, :price)
    assert_equal [@close_at, "cancelled", "filled"], [released, rest.reload.status, buy.reload.status]
    assert_equal released, rest.hold.released_at
  end

  test "T2 시가 행이 있어도 종가는 따로 돈다: 같은 날 open 행 1 · close 행 1" do
    place("buy", qty: 1, price: 50_000, at: KST.local(2026, 11, 2, 8, 40, 0))
    place("sell", qty: 1, price: 50_000, at: KST.local(2026, 11, 2, 8, 40, 0))
    Securities::Auction.open!(asset: @equity, trade_date: DAY, at: @nine)
    close = close!

    assert_equal %w[close open], Securities::Auction.where(asset_id: @equity.id, trade_date: DAY).order(:session).pluck(:session)
    assert_equal ["close", 0], [close.session, close.qty]
  end

  test "T2 끄기: single_price false 는 들어온 순서대로 체결된 뒤 같은 일괄 취소 — 뒤에 온 48,000 매도는 체결 없이 cancelled" do
    buy = place("buy", qty: 1, price: 50_000)
    sell_a = place("sell", qty: 1, price: 49_000)
    sell_b = place("sell", qty: 1, price: 48_000)

    auction = close!(single_price: false)

    assert_equal ["sequential", nil, 1, "close"], [auction.mode, auction.price, auction.qty, auction.session]
    execution = Securities::Execution.sole
    # before_seq 가 없으면 매수가 더 싼 48,000 매도부터 만나 48,000 근처에서 체결된다. 들어온 순서면 매수 ↔ 49,000 매도, 50,000 이다.
    assert_equal [buy.id, sell_a.id, 50_000, 1], [execution.buy_order_id, execution.sell_order_id, execution.price, execution.qty]
    assert_equal %w[filled filled cancelled], [buy, sell_a, sell_b].map { |o| o.reload.status }
    assert_equal [@close_at, 100], [sell_b.hold.released_at, available(sell_b)]
  end

  test "종가 단일가에 체결이 없어도 남은 주문은 전부 cancelled 이고 행은 price NULL · qty 0" do
    buy = place("buy", qty: 1, price: 49_000)
    sell = place("sell", qty: 1, price: 51_000)

    auction = close!

    assert_equal ["single", nil, 0], [auction.mode, auction.price, auction.qty]
    assert_equal %w[cancelled cancelled], [buy.reload.status, sell.reload.status]
    assert_equal [@close_at, @close_at], [buy.hold.released_at, sell.hold.released_at]
  end

  # minitest 6 에는 Object#stub 이 없다. random_end_seconds 를 armed 동안만 덮는다(auction_test 의 SinglePriceOverride 와 같은 방식).
  module RandomEndOverride
    def random_end_seconds
      RandomEndOverride.armed ? RandomEndOverride.value : super
    end

    class << self
      attr_accessor :armed, :value
    end
  end
  Securities::Clock.singleton_class.prepend(RandomEndOverride)

  test "T3 random_end_at: 같은 인자는 같은 값이고 open 은 [09:00:00, 09:00:30], close 는 [15:30:00, 15:30:30]" do
    args = { trade_date: DAY, asset_id: 7, session: "open", seed: 42 }
    assert_equal Securities::Auction.random_end_at(**args), Securities::Auction.random_end_at(**args)

    opens = (0...60).map { |s| Securities::Auction.random_end_at(**args, seed: s) }
    closes = (0...60).map { |s| Securities::Auction.random_end_at(**args, session: "close", seed: s) }

    assert opens.all? { |t| t.between?(KST.local(2026, 11, 2, 9, 0, 0), KST.local(2026, 11, 2, 9, 0, 30)) }
    assert closes.all? { |t| t.between?(KST.local(2026, 11, 2, 15, 30, 0), KST.local(2026, 11, 2, 15, 30, 30)) }
    assert_operator opens.uniq.size, :>, 1 # seed 가 값에 반영된다
    assert_equal "Asia/Seoul", opens.first.time_zone.name
    assert_raises(ArgumentError) { Securities::Auction.random_end_at(**args, session: "x") }
  end

  test "T3 random_end_at 은 config/securities_clock.yml 의 random_end_seconds 를 읽는다" do
    assert_equal 30, Securities::Clock.random_end_seconds # 덮기 전: 설정 파일 값

    RandomEndOverride.value = 0
    RandomEndOverride.armed = true
    times = (0...10).map { |s| Securities::Auction.random_end_at(trade_date: DAY, asset_id: 7, session: "close", seed: s) }

    assert_equal [KST.local(2026, 11, 2, 15, 30, 0)], times.uniq # 0 초면 항상 마감 정각이다
  ensure
    RandomEndOverride.armed = false
  end

  test "D4 Asset has_many :auctions 는 restrict_with_exception" do
    close!
    assert_equal 1, @equity.auctions.count
    assert_raises(ActiveRecord::DeleteRestrictionError) { @equity.destroy }
  end
end
