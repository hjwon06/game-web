require "test_helper"
require_relative "../../support/securities_race"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# 결제와 접수의 경합. place_order_concurrency_test 와 같은 방식이다: 트랜잭션 테스트를 끄고 스레드마다 별도 커넥션을 쓴다.
# A 는 바깥 트랜잭션에서 Settle 을 끝낸 채 커밋하지 않고 대기하고, B 는 결제에 묶인 계좌로 PlaceOrder 한다.
#   - B 는 계좌 행 FOR UPDATE 에서 대기해야 한다(Settle 이 영향받는 계좌를 잠근다).
#   - A 커밋 뒤 B 의 가능 수량 판정은 결제 뒤 값이다: 산 주식 2주 전량 매도가 접수되고 그 뒤 가능 수량은 0 이다.
#   - Settle 의 계좌 잠금을 빼면 B 는 기다리지 않아 "계좌 행에서 대기" 단언이 실패한다.
#
# 정리: 이 테스트가 만든 행만 FK 순서로 지운다. 이 테스트는 원장 행을 만들 수밖에 없다(Settle 이 쓰고 커밋해야 경합이 된다).
# 원장 행은 트리거가 지우지 못하게 막으므로, 정리하는 트랜잭션 안에서만 그 트리거를 끄고 지운 뒤 다시 켠다.
# 트랜잭션 DDL 이라 도중에 실패하면 트리거는 켜진 채로 되돌아간다. TRUNCATE 는 쓰지 않는다.
class Securities::SettleConcurrencyTest < ActiveSupport::TestCase
  include SecuritiesRace

  self.use_transactional_tests = false

  KST = ActiveSupport::TimeZone["Asia/Seoul"]
  DAYS = [Date.new(2026, 11, 2), Date.new(2026, 11, 3), Date.new(2026, 11, 4), Date.new(2026, 11, 5)].freeze
  MON = DAYS[0]
  WED = DAYS[2]
  APPEND_ONLY_TRIGGER = "ledger_entries_no_update_delete".freeze
  ACCOUNT_ROW = /FROM "accounts"[^;]*FOR UPDATE/i
  ROW_WAIT = %w[transactionid tuple].freeze

  setup do
    @suffix = SecureRandom.hex(4)
    @created_assets = []
    @cash = find_or_create_asset("VKRW", name: "가상원화", kind: "cash")
    @equity = find_or_create_asset("VT-S6-#{@suffix}", name: "가상종목", kind: "equity", base_price: 50_000)
    @clearing_created = !Securities::Account.exists?(code: Securities::Seed::CLEARING_CODE)
    @clearing = Securities::Account.find_by(code: Securities::Seed::CLEARING_CODE) ||
                Securities::Account.create!(code: Securities::Seed::CLEARING_CODE, name: "가상청산소", kind: "clearing")
    @buyer = Securities::Account.create!(code: "VT-S6B-#{@suffix}", name: "가상매수자", kind: "investor")
    @seller = Securities::Account.create!(code: "VT-S6S-#{@suffix}", name: "가상매도자", kind: "investor")
    Securities::Position.create!(account: @buyer, asset: @cash, qty: 1_000_000)
    Securities::Position.create!(account: @seller, asset: @equity, qty: 10)
    @created_days = DAYS.reject { |d| Securities::MarketDay.exists?(trade_date: d) }
    @created_days.each { |d| Securities::MarketDay.create!(trade_date: d, business_day: true) }
    @mon = KST.local(2026, 11, 2, 10, 0, 0)
    @wed = KST.local(2026, 11, 4, 10, 0, 0)
    @wed_close = KST.local(2026, 11, 4, 16, 0, 0)
    Securities::Auction.create!(asset: @equity, trade_date: MON, session: "open", mode: "sequential", qty: 0, ran_at: @mon)

    refute Securities::Settlement.exists?(settle_date: WED), "수요일 결제 행이 남아 있다 — 이전 실행의 잔여물이다"
    place(@seller, "sell", client_key: "s-#{@suffix}", at: @mon)
    place(@buyer, "buy", client_key: "b-#{@suffix}", at: @mon)
  end

  teardown do
    settlement_ids = Securities::Settlement.where(settle_date: WED).pluck(:id)
    conn = Securities::Record.lease_connection
    Securities::Record.transaction do
      conn.execute("ALTER TABLE ledger_entries DISABLE TRIGGER #{APPEND_ONLY_TRIGGER}")
      Securities::LedgerEntry.where(settlement_id: settlement_ids).delete_all
      conn.execute("ALTER TABLE ledger_entries ENABLE TRIGGER #{APPEND_ONLY_TRIGGER}")
    end

    account_ids = [@buyer.id, @seller.id]
    order_ids = Securities::Order.where(account_id: account_ids).pluck(:id)
    Securities::Execution.where(asset_id: @equity.id).delete_all
    Securities::Settlement.where(id: settlement_ids).delete_all
    Securities::Auction.where(asset_id: @equity.id).delete_all
    Securities::Hold.where(order_id: order_ids).delete_all
    Securities::Order.where(id: order_ids).delete_all
    Securities::Position.where(account_id: account_ids).delete_all
    Securities::Account.where(id: account_ids).delete_all
    Securities::Account.where(id: @clearing.id).delete_all if @clearing_created
    Securities::Asset.where(id: @created_assets).delete_all
    Securities::MarketDay.where(trade_date: @created_days).delete_all
  end

  def find_or_create_asset(code, **attrs)
    Securities::Asset.find_by(code: code) || Securities::Asset.create!(code: code, **attrs).tap { |a| @created_assets << a.id }
  end

  def place(account, side, client_key:, at:, qty: 2)
    Securities::PlaceOrder.call(account: account, asset: @equity, side: side, order_type: "limit", qty: qty,
                                price: 50_000, client_key: client_key, at: at)
  end

  test "T6 A 가 결제하고 커밋 전 대기하면 B 의 접수는 계좌 행에서 대기하고 결제 뒤 가능 수량으로 판정된다" do
    execution = Securities::Execution.where(asset_id: @equity.id).sole
    assert_equal [WED, nil], [execution.settle_date, execution.settlement_id], "월요일 체결이 미결제로 있어야 한다"
    assert_equal 2, Securities::Available.for(@buyer, @equity), "결제 전 가능 수량은 미결제 체결 몫이다"

    waiting, b_alive, settlement, b_order = race(
      a: -> { Securities::Settle.call(settle_date: WED, at: @wed_close) },
      b: -> { place(@buyer, "sell", client_key: "w-#{@suffix}", at: @wed) },
      expect: ACCOUNT_ROW
    )

    assert_blocked waiting, events: ROW_WAIT, message: "B 는 결제가 잡은 계좌 행 FOR UPDATE 에서 대기해야 한다 — 직렬화 없음"
    assert b_alive, "B 는 A 커밋 전에 끝나면 안 된다"
    assert_equal "settled", settlement.status
    assert_equal ["accepted", nil], [b_order.status, b_order.reject_reason]
    assert_equal 2, Securities::Position.find_by!(account_id: @buyer.id, asset_id: @equity.id).qty
    assert_equal settlement.id, execution.reload.settlement_id
    assert_equal 4, Securities::LedgerEntry.where(settlement_id: settlement.id).count
    assert_equal 0, Securities::Available.for(@buyer, @equity), "positions 2 − 열린 홀드 2. 미결제 몫이 남아 있으면 2 가 된다"
  end
end
