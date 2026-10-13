require "test_helper"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# 기준가 갱신(BasePrice.roll!). 체결은 실제 경로(PlaceOrder → Auction.open!/close!)로 만든다. 기준가 50,000.
# 변이 검사: roll! 을 종가 세션 체결만으로 바꾸면 T3, 종목 조건을 빼면 T4 가 실패해야 한다.
class Securities::BasePriceTest < ActiveSupport::TestCase
  KST = ActiveSupport::TimeZone["Asia/Seoul"]
  DAY = Date.new(2026, 11, 2)

  setup do
    @cash = Securities::Asset.create!(code: "VKRW", name: "가상원화", kind: "cash")
    @equity = Securities::Asset.create!(code: "VT-EQ", name: "가상종목", kind: "equity", base_price: 50_000)
    @other = Securities::Asset.create!(code: "VT-E2", name: "가상종목2", kind: "equity", base_price: 50_000)
    (2..6).each { |d| Securities::MarketDay.create!(trade_date: Date.new(2026, 11, d), business_day: true) }
    @nine = KST.local(2026, 11, 2, 9, 0, 0)
    @ten = KST.local(2026, 11, 2, 10, 0, 0)
    @closing = KST.local(2026, 11, 2, 15, 25, 0)
    @close_at = KST.local(2026, 11, 2, 15, 30, 5)
    @n = 0
  end

  def place(side, qty:, price:, at:, asset: @equity)
    account = Securities::Account.create!(code: "VT-#{@n += 1}", name: "가상투자자", kind: "investor")
    if side == "buy"
      Securities::Position.create!(account: account, asset: @cash, qty: 10_000_000)
    else
      Securities::Position.create!(account: account, asset: asset, qty: 100)
    end
    Securities::PlaceOrder.call(account: account, asset: asset, side: side, order_type: "limit", qty: qty, price: price,
                                client_key: "k-#{@n}", at: at)
  end

  # 장중 체결 하나(51,000). 시가 행을 만들어 접속매매를 연 뒤 매도 → 매수로 체결시킨다.
  def intraday_trade(asset = @equity)
    Securities::Auction.open!(asset: asset, trade_date: DAY, at: @nine)
    place("sell", qty: 1, price: 51_000, at: @ten, asset: asset)
    place("buy", qty: 1, price: 51_000, at: @ten, asset: asset)
  end

  def close!(asset = @equity, **opts)
    Securities::Auction.close!(asset: asset, trade_date: DAY, at: @close_at, **opts)
  end

  def roll!(asset = @equity)
    Securities::BasePrice.roll!(asset: asset, trade_date: DAY)
  end

  test "T1 close 행이 없으면 예외를 내고 기준가는 그대로다" do
    intraday_trade

    assert_raises(Securities::BasePrice::NoClose) { roll! }
    assert_equal 50_000, @equity.reload.base_price
  end

  test "T2 종가 세션의 마지막 체결가(id 최대)가 기준가가 된다 — 장중 체결가가 아니다" do
    intraday_trade
    place("sell", qty: 1, price: 48_000, at: @closing)
    place("sell", qty: 1, price: 49_000, at: @closing)
    place("buy", qty: 1, price: 50_000, at: @closing)
    place("buy", qty: 1, price: 50_000, at: @closing)
    close!(single_price: false) # 끄기: 접수 순서대로 접속매매라 가격이 둘이다

    at_close = Securities::Execution.where(executed_at: @close_at).order(:id).to_a
    assert_equal 2, at_close.map(&:price).uniq.size
    assert_equal 51_000, Securities::Execution.where(executed_at: @ten).sole.price

    assert_equal at_close.last.price, roll!
    assert_equal at_close.last.price, @equity.reload.base_price
  end

  test "T3 종가 세션에 체결이 없으면 장중 마지막 체결(executed_at, id 최대)의 가격이 기준가가 된다" do
    intraday_trade
    eleven = KST.local(2026, 11, 2, 11, 0, 0)
    place("sell", qty: 1, price: 52_000, at: eleven)
    place("buy", qty: 1, price: 52_000, at: eleven)
    close!

    assert_equal [51_000, 52_000], Securities::Execution.order(:id).pluck(:price)
    assert_empty Securities::Execution.where(executed_at: @close_at), "종가 세션에는 체결이 없다"

    assert_equal 52_000, roll!
    assert_equal 52_000, @equity.reload.base_price
    assert_equal 52_000, roll!, "두 번 불러도 같다"
  end

  test "T3 그날 체결이 하나도 없으면 nil 이고 기준가는 그대로다" do
    Securities::Auction.open!(asset: @other, trade_date: DAY, at: @nine)
    close!(@other)
    assert_equal 0, Securities::Execution.count

    assert_nil roll!(@other)
    assert_equal 50_000, @other.reload.base_price
  end

  test "T4 멱등이고 다른 종목의 같은 시각 체결을 보지 않는다" do
    intraday_trade
    place("sell", qty: 2, price: 49_000, at: @closing)
    place("buy", qty: 2, price: 49_000, at: @closing)
    close!
    # 다른 종목이 같은 종가 시각에 더 큰 id 로 다른 가격에 체결한다.
    Securities::Auction.open!(asset: @other, trade_date: DAY, at: @nine)
    place("sell", qty: 1, price: 40_000, at: @closing, asset: @other)
    place("buy", qty: 1, price: 40_000, at: @closing, asset: @other)
    close!(@other)
    assert_operator Securities::Execution.where(asset_id: @other.id).minimum(:id), :>, Securities::Execution.where(asset_id: @equity.id).maximum(:id)

    assert_equal 49_000, roll!
    assert_equal 49_000, roll!
    assert_equal [49_000, 40_000], [@equity.reload.base_price, roll!(@other)]
  end
end
