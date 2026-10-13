require "test_helper"
require_relative "../../support/securities_race"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# 트랜잭션 테스트를 끄고 스레드마다 별도 커넥션으로 실제 잠금 경합을 만든다(test/concurrency_test.rb 와 같은 방식).
# A 는 바깥 트랜잭션에서 접수하고 커밋하지 않은 채 대기하고, B 는 그동안 들어온다. 구분 기준은 B 가 대기한 SQL 이다.
#   - PlaceOrder 의 advisory lock 줄을 지우면 T3 이 "advisory 에서 대기" 단언에서 실패해야 한다.
#   - PlaceOrder 의 계좌 FOR UPDATE 를 지우면 T4 가 "계좌 행에서 대기" 단언에서 실패해야 한다.
# 정리는 이 테스트가 만든 행만 FK 순서로 DELETE 한다. TRUNCATE CASCADE 는 원장 TRUNCATE 트리거에 걸리므로 쓰지 않고,
# 원장 행은 만들지 않는다(positions 를 직접 넣는다).
class Securities::PlaceOrderConcurrencyTest < ActiveSupport::TestCase
  include SecuritiesRace

  self.use_transactional_tests = false

  KST = ActiveSupport::TimeZone["Asia/Seoul"]
  MONDAY = Date.new(2026, 11, 2)

  setup do
    @suffix = SecureRandom.hex(4)
    @created_assets = []
    @cash = find_or_create_asset("VKRW", name: "가상원화", kind: "cash")
    @equity = find_or_create_asset("VT-C-#{@suffix}", name: "가상종목", kind: "equity", base_price: 50_000)
    @account = Securities::Account.create!(code: "VT-C-#{@suffix}", name: "가상투자자", kind: "investor")
    Securities::Position.create!(account: @account, asset: @cash, qty: 1_000_000)
    @market_day_created = !Securities::MarketDay.exists?(trade_date: MONDAY)
    Securities::MarketDay.create!(trade_date: MONDAY, business_day: true) if @market_day_created
    @at = KST.local(2026, 11, 2, 10, 0, 0)
  end

  teardown do
    order_ids = Securities::Order.where(account_id: @account.id).pluck(:id)
    Securities::Hold.where(order_id: order_ids).delete_all
    Securities::Order.where(id: order_ids).delete_all
    Securities::Position.where(account_id: @account.id).delete_all
    Securities::Account.where(id: @account.id).delete_all
    Securities::Asset.where(id: @created_assets).delete_all
    Securities::MarketDay.where(trade_date: MONDAY).delete_all if @market_day_created
  end

  def find_or_create_asset(code, **attrs)
    Securities::Asset.find_by(code: code) || Securities::Asset.create!(code: code, **attrs).tap { |a| @created_assets << a.id }
  end

  def place(key:, qty:, price: 50_000)
    Securities::PlaceOrder.call(account: @account, asset: @equity, side: "buy", order_type: "limit", qty: qty,
                                price: price, client_key: key, at: @at)
  end

  ADVISORY_KEY = /pg_advisory_xact_lock\(\s*hashtext/i
  ACCOUNT_ROW = /FOR UPDATE/i
  ROW_WAIT = %w[transactionid tuple].freeze

  # A · B 를 겹쳐 실행한다. B 의 Conflict 는 값으로 받아 단언에서 본다.
  def place_race(a:, b:, expect:)
    b_call = lambda do
      place(**b)
    rescue Securities::PlaceOrder::Conflict => e
      e
    end
    race(a: -> { place(**a) }, b: b_call, expect: expect)
  end

  test "T3 같은 키 · 같은 내용: B 는 advisory lock 에서 대기하고 A 커밋 뒤 같은 주문을 받는다" do
    waiting, b_alive, a_order, b_order = place_race(
      a: { key: "same-#{@suffix}", qty: 2 }, b: { key: "same-#{@suffix}", qty: 2 }, expect: ADVISORY_KEY
    )

    assert_blocked waiting, events: %w[advisory], message: "B 는 같은 키 advisory lock 에서 대기해야 한다 — 직렬화 없음"
    assert b_alive, "B 는 A 커밋 전에 끝나면 안 된다"
    assert_equal a_order.id, b_order.id
    assert_equal 1, Securities::Order.where(account_id: @account.id).count
    assert_equal 1, Securities::Hold.where(account_id: @account.id).count
  end

  test "T3 같은 키 · 다른 내용: B 는 대기했다가 Conflict 를 받고 주문 · 홀드는 1 이다" do
    waiting, b_alive, _a_order, b_result = place_race(
      a: { key: "diff-#{@suffix}", qty: 2 }, b: { key: "diff-#{@suffix}", qty: 3 }, expect: ADVISORY_KEY
    )

    assert_blocked waiting, events: %w[advisory], message: "B 는 같은 키 advisory lock 에서 대기해야 한다"
    assert b_alive
    assert_kind_of Securities::PlaceOrder::Conflict, b_result
    assert_equal 1, Securities::Order.where(account_id: @account.id).count
    assert_equal 1, Securities::Hold.where(account_id: @account.id).count
  end

  test "T4 현금 1,000,000 에 600,000 매수 2건: B 는 계좌 행에서 대기하고 A 커밋 뒤 insufficient 로 거절된다" do
    waiting, b_alive, a_order, b_order = place_race(
      a: { key: "a-#{@suffix}", qty: 12 }, b: { key: "b-#{@suffix}", qty: 12 }, expect: ACCOUNT_ROW
    )

    assert_blocked waiting, events: ROW_WAIT, message: "B 는 계좌 행 FOR UPDATE 에서 대기해야 한다 — 직렬화 없음"
    refute_match(/advisory/i, waiting.query, "키가 달라 advisory 에서는 대기하지 않는다")
    assert b_alive, "B 는 A 커밋 전에 끝나면 안 된다"
    assert_equal "accepted", a_order.status
    assert_equal ["rejected", "insufficient"], [b_order.status, b_order.reject_reason]
    assert_equal 600_000, Securities::Hold.where(account_id: @account.id, released_at: nil).sum(:qty)
    assert_equal 1, Securities::Hold.where(account_id: @account.id).count
    assert_equal 2, Securities::Order.where(account_id: @account.id).count
  end
end
