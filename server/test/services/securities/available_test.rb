require "test_helper"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# 가능 수량 = 결제분 + 미결제 체결로 들어올 것 − 나갈 것 − 열린 홀드. 체결 행은 직접 넣는다(체결 엔진은 범위 밖).
class Securities::AvailableTest < ActiveSupport::TestCase
  setup do
    @cash = Securities::Asset.create!(code: "VKRW", name: "가상원화", kind: "cash")
    @equity = Securities::Asset.create!(code: "VT-EQ", name: "가상종목", kind: "equity", base_price: 50_000)
    @me = Securities::Account.create!(code: "VT-ME", name: "가상투자자 나", kind: "investor")
    @other = Securities::Account.create!(code: "VT-OTHER", name: "가상투자자 상대", kind: "investor")
    Securities::Position.create!(account: @me, asset: @cash, qty: 1_000_000)
    Securities::Position.create!(account: @me, asset: @equity, qty: 10)
    @seq = 0
  end

  def available(asset)
    Securities::Available.for(@me, asset)
  end

  def order(account, side, qty: 1, price: 50_000)
    @seq += 1
    Securities::Order.create!(client_key: "avail-#{@seq}", account: account, asset: @equity, side: side,
                              order_type: "limit", price: price, qty: qty, status: "accepted")
  end

  def hold(order, asset, qty, released_at: nil)
    Securities::Hold.create!(order: order, account: order.account, asset: asset, qty: qty, released_at: released_at)
  end

  # 내가 산 체결(상대가 판 것)이면 buyer: @me. settlement 는 NULL(미결제)이 기본이다.
  def execution(price:, qty:, buyer:, seller:, settlement: nil)
    Securities::Execution.create!(
      asset: @equity, buy_order: order(buyer, "buy", qty: qty, price: price),
      sell_order: order(seller, "sell", qty: qty, price: price), price: price, qty: qty,
      trade_date: Date.new(2026, 11, 2), settle_date: Date.new(2026, 11, 4), settlement: settlement
    )
  end

  test "홀드가 없으면 결제분 그대로다" do
    assert_equal 1_000_000, available(@cash)
    assert_equal 10, available(@equity)
  end

  test "열린 홀드는 차감하고 풀린 홀드(released_at)는 차감하지 않는다" do
    hold(order(@me, "buy", qty: 6, price: 50_000), @cash, 300_000)
    hold(order(@me, "sell", qty: 4), @equity, 4)
    hold(order(@me, "buy", qty: 2, price: 50_000), @cash, 100_000, released_at: Time.utc(2026, 11, 2, 1, 0, 0))

    assert_equal 700_000, available(@cash)
    assert_equal 6, available(@equity)
  end

  test "남의 홀드는 내 가능 수량에 영향이 없다" do
    hold(order(@other, "buy", qty: 6, price: 50_000), @cash, 300_000)

    assert_equal 1_000_000, available(@cash)
  end

  test "미결제 매수 체결은 종목이 들어오고 현금(체결가 × 수량)이 나간다" do
    execution(price: 50_000, qty: 3, buyer: @me, seller: @other)

    assert_equal 13, available(@equity)
    assert_equal 850_000, available(@cash)
  end

  test "미결제 매도 체결은 종목이 나가고 현금이 들어온다(당일 매도 대금으로 매수가 된다)" do
    execution(price: 51_000, qty: 2, buyer: @other, seller: @me)

    assert_equal 8, available(@equity)
    assert_equal 1_102_000, available(@cash)
  end

  test "당일 산 주식은 결제 전에도 매도 가능 수량에 잡힌다" do
    execution(price: 50_000, qty: 3, buyer: @me, seller: @other)
    hold(order(@me, "sell", qty: 12), @equity, 12)

    assert_equal 1, available(@equity) # 10 + 3 − 12
  end

  test "결제가 끝난 체결은 positions 에 이미 반영됐으므로 세지 않는다, pending 은 센다" do
    pending = Securities::Settlement.create!(settle_date: Date.new(2026, 11, 4), status: "pending")
    settled = Securities::Settlement.create!(settle_date: Date.new(2026, 11, 3), status: "settled")
    execution(price: 50_000, qty: 3, buyer: @me, seller: @other, settlement: pending)
    execution(price: 50_000, qty: 5, buyer: @me, seller: @other, settlement: settled)

    assert_equal 13, available(@equity)
    assert_equal 850_000, available(@cash)
  end

  test "체결이 없는 계좌 · 종목 조합은 0 이다" do
    assert_equal 0, Securities::Available.for(@other, @equity)
    assert_equal 0, Securities::Available.for(@other, @cash)
  end
end
