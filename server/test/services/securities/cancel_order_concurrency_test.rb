require "test_helper"
require_relative "../../support/securities_race"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# 체결과 취소의 경합. place_order_concurrency_test 와 같은 방식이다: 트랜잭션 테스트를 끄고 스레드마다 별도 커넥션을 쓴다.
# A 는 바깥 트랜잭션에서 메이커 주문을 전량 체결한 채 커밋하지 않고 대기하고, B 는 그 주문을 취소한다.
#   - B 는 메이커 계좌 행(A 가 안 잠근다)을 지난 뒤 책 잠금(pg_advisory_xact_lock)에서 대기해야 한다.
#   - A 커밋 뒤 B 의 결과는 filled 다(cancelled 가 아니다).
#   - CancelOrder 의 책 잠금 · 주문 FOR UPDATE 를 둘 다 빼면 B 는 낡은 accepted 를 읽고 UPDATE 에서 대기해
#     "책 잠금에서 대기" 단언과 filled 단언이 실패한다.
# 정리는 이 테스트가 만든 행만 FK 순서로 DELETE 한다(체결 행 먼저). 원장 행은 만들지 않는다.
class Securities::CancelOrderConcurrencyTest < ActiveSupport::TestCase
  include SecuritiesRace

  self.use_transactional_tests = false

  KST = ActiveSupport::TimeZone["Asia/Seoul"]
  MONDAY = Date.new(2026, 11, 2)
  DAYS = [Date.new(2026, 11, 2), Date.new(2026, 11, 3), Date.new(2026, 11, 4)].freeze # 체결일 + 결제일 계산에 3일이 필요하다

  setup do
    @suffix = SecureRandom.hex(4)
    @created_assets = []
    @cash = find_or_create_asset("VKRW", name: "가상원화", kind: "cash")
    @equity = find_or_create_asset("VT-X-#{@suffix}", name: "가상종목", kind: "equity", base_price: 50_000)
    @maker = Securities::Account.create!(code: "VT-XM-#{@suffix}", name: "가상메이커", kind: "investor")
    @taker = Securities::Account.create!(code: "VT-XT-#{@suffix}", name: "가상테이커", kind: "investor")
    Securities::Position.create!(account: @maker, asset: @equity, qty: 10)
    Securities::Position.create!(account: @taker, asset: @cash, qty: 1_000_000)
    @created_days = DAYS.reject { |d| Securities::MarketDay.exists?(trade_date: d) }
    @created_days.each { |d| Securities::MarketDay.create!(trade_date: d, business_day: true) }
    @at = KST.local(2026, 11, 2, 10, 0, 0)
    @later = KST.local(2026, 11, 2, 10, 30, 0)
    # 시작 문(D7): 그날 시가 행이 있어야 접수가 Match 를 부른다.
    Securities::Auction.create!(asset: @equity, trade_date: MONDAY, session: "open", mode: "sequential", qty: 0, ran_at: @at)
  end

  teardown do
    account_ids = [@maker.id, @taker.id]
    order_ids = Securities::Order.where(account_id: account_ids).pluck(:id)
    Securities::Auction.where(asset_id: @equity.id).delete_all
    Securities::Execution.where(asset_id: @equity.id).delete_all
    Securities::Hold.where(order_id: order_ids).delete_all
    Securities::Order.where(id: order_ids).delete_all
    Securities::Position.where(account_id: account_ids).delete_all
    Securities::Account.where(id: account_ids).delete_all
    Securities::Asset.where(id: @created_assets).delete_all
    Securities::MarketDay.where(trade_date: @created_days).delete_all
  end

  def find_or_create_asset(code, **attrs)
    Securities::Asset.find_by(code: code) || Securities::Asset.create!(code: code, **attrs).tap { |a| @created_assets << a.id }
  end

  # CancelOrder 가 잡는 책 잠금: pg_advisory_xact_lock(Match::BOOK_NS, asset_id). 값은 SQL 에 인라인된다.
  BOOK_LOCK = /pg_advisory_xact_lock\(\s*#{Securities::Match::BOOK_NS}\b/i

  test "T3 A 가 메이커를 전량 체결하고 커밋 전 대기하면 B 의 취소는 책 잠금에서 대기하고 결과는 filled 다" do
    maker_order = Securities::PlaceOrder.call(account: @maker, asset: @equity, side: "sell", order_type: "limit",
                                              qty: 2, price: 50_000, client_key: "m-#{@suffix}", at: @at)
    assert_equal "accepted", maker_order.status

    waiting, b_alive, a_order, b_order = race(
      a: -> {
        Securities::PlaceOrder.call(account: @taker, asset: @equity, side: "buy", order_type: "limit", qty: 2,
                                    price: 50_000, client_key: "t-#{@suffix}", at: @at)
      },
      b: -> { Securities::CancelOrder.call(order: maker_order, at: @later) },
      expect: BOOK_LOCK
    )

    assert_blocked waiting, events: %w[advisory], message: "B 는 책 잠금에서 대기해야 한다 — 체결과 취소가 직렬화되지 않는다"
    assert b_alive, "B 는 A 커밋 전에 끝나면 안 된다"
    assert_equal "filled", a_order.status
    assert_equal "filled", b_order.status, "체결과 겹친 취소는 체결 뒤 상태(filled)를 봐야 한다"

    maker_order.reload
    assert_equal ["filled", 2], [maker_order.status, maker_order.filled_qty]
    assert_equal @at, maker_order.hold.released_at, "취소가 홀드 해제 시각을 덮어쓰면 안 된다"
    assert_equal 1, Securities::Execution.where(asset_id: @equity.id).count
  end
end
