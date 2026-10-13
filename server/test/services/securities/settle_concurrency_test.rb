require "test_helper"
require_relative "../../support/securities_race"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# 결제와 접수의 경합. place_order_concurrency_test 와 같은 방식이다: 트랜잭션 테스트를 끄고 스레드마다 별도 커넥션을 쓴다.
# A 는 바깥 트랜잭션에서 Settle 을 끝낸 채 커밋하지 않고 대기하고, B 는 결제에 묶인 계좌로 PlaceOrder 한다.
#   - B 는 계좌 행 FOR UPDATE 에서 대기해야 한다(Settle 이 영향받는 계좌를 잠근다).
#   - A 커밋 뒤 B 의 가능 수량 판정은 결제 뒤 값이다: 산 주식 2주 전량 매도가 접수되고 그 뒤 가능 수량은 0 이다.
#   - T6 의 대기는 원장 INSERT 의 FK 잠금(계좌 행 FOR KEY SHARE, 접수의 FOR UPDATE 와 충돌)으로도 생긴다. 그래서 Settle 의
#     Account.lock 을 빼도 T6 은 통과한다(실측). T6 의 accepted · 가능 수량 단언도 결제 전후 값이 같아(T4) 잠금을 구별하지 못한다.
#   - Settle 의 명시 잠금을 증명하는 것은 T6b 다: 순액이 전부 0 인 계좌 X 는 원장 행이 없어 FK 잠금도 없으므로,
#     B 가 X 의 계좌 행에서 기다린다면 그것은 Settle 의 Account.lock 때문이다. 그 잠금을 빼면 T6b 의 대기 단언이 실패한다.
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
    @extra_account_ids = []
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

    account_ids = [@buyer.id, @seller.id] + Array(@extra_account_ids)
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

  # T6b 용 투자자 계좌. teardown 이 지우도록 id 를 모아 둔다.
  def make_investor(tag, cash: nil, equity: nil)
    account = Securities::Account.create!(code: "VT-S6#{tag}-#{@suffix}", name: "가상#{tag}", kind: "investor")
    @extra_account_ids << account.id
    Securities::Position.create!(account: account, asset: @cash, qty: cash) if cash
    Securities::Position.create!(account: account, asset: @equity, qty: equity) if equity
    account
  end

  def ledger_rows_of(account)
    Securities::LedgerEntry.where(from_account_id: account.id).or(Securities::LedgerEntry.where(to_account_id: account.id))
  end

  test "T6b 순액이 0 인 계좌도 Settle 이 명시적으로 잠근다 — 원장 행이 없어 FK 잠금이 생기지 않는다" do
    x = make_investor("X", cash: 1_000_000)
    y = make_investor("Y", equity: 2)
    z = make_investor("Z", cash: 1_000_000)
    place(y, "sell", client_key: "ys-#{@suffix}", at: @mon)
    place(x, "buy", client_key: "xb-#{@suffix}", at: @mon)   # Y 에게서 산다
    place(z, "buy", client_key: "zb-#{@suffix}", at: @mon)
    place(x, "sell", client_key: "xs-#{@suffix}", at: @mon)  # Z 에게 판다(같은 종목 · 가격 · 수량)

    x_orders = Securities::Order.where(account_id: x.id).pluck(:id)
    x_fills = Securities::Execution.where(buy_order_id: x_orders).or(Securities::Execution.where(sell_order_id: x_orders))
    assert_equal [WED, WED], x_fills.order(:id).pluck(:settle_date), "X 의 체결 둘이 수요일 결제여야 한다"
    assert_equal [nil, nil], x_fills.order(:id).pluck(:settlement_id), "결제 전에는 미결제다"
    positions_before = Securities::Position.where(account_id: x.id).order(:asset_id).pluck(:asset_id, :qty)

    waiting, b_alive, settlement, b_order = race(
      a: -> { Securities::Settle.call(settle_date: WED, at: @wed_close) },
      b: -> { place(x, "buy", client_key: "w-#{@suffix}", at: @wed, qty: 1) },
      expect: ACCOUNT_ROW
    )

    # X 는 원장 행이 하나도 없다 — B 의 대기를 FK 잠금으로 설명할 수 없다. 남는 원인은 Settle 의 Account.lock 뿐이다.
    assert_equal 0, ledger_rows_of(x).count, "X 는 순액 0 이라 원장 행이 없어야 한다(이 단언이 FK 잠금 가설을 지운다)"
    assert_blocked waiting, events: ROW_WAIT, message: "B 는 원장 행이 없는 X 의 계좌 행 FOR UPDATE 에서 대기해야 한다 — Settle 의 명시 잠금"
    assert b_alive, "B 는 A 커밋 전에 끝나면 안 된다"
    assert_equal "settled", settlement.status
    assert_equal ["accepted", nil], [b_order.status, b_order.reject_reason]
    assert_equal 8, Securities::LedgerEntry.where(settlement_id: settlement.id).count,
                 "결제는 실제로 썼다: 매수 · 매도(4) + Y(2) + Z(2). X 만 0"
    assert_equal positions_before, Securities::Position.where(account_id: x.id).order(:asset_id).pluck(:asset_id, :qty)
    assert_equal [settlement.id, settlement.id], x_fills.order(:id).pluck(:settlement_id), "X 의 체결 둘 다 묶여야 한다"
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
