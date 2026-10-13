require "test_helper"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# 대사(Reconcile). 정상 상태는 실제 경로(PlaceOrder → Match → Settle)로 만들고, 틀리게 하는 것만 update_all · INSERT 로 한다.
# 항목마다 "틀리기 전에는 비어 있었다"를 먼저 보여 준다 — 대사가 원래 시끄러운 게 아니라는 증거다.
class Securities::ReconcileTest < ActiveSupport::TestCase
  KST = ActiveSupport::TimeZone["Asia/Seoul"]
  MON = Date.new(2026, 11, 2)
  TUE = Date.new(2026, 11, 3)
  WED = Date.new(2026, 11, 4)
  THU = Date.new(2026, 11, 5)

  setup do
    @cash = Securities::Asset.create!(code: Securities::Asset::CASH_CODE, name: "가상원화", kind: "cash")
    @equity = Securities::Asset.create!(code: "VT-EQ", name: "가상종목", kind: "equity", base_price: 50_000)
    (2..6).each { |d| Securities::MarketDay.create!(trade_date: Date.new(2026, 11, d), business_day: true) }
    @clearing = Securities::Account.create!(code: Securities::Seed::CLEARING_CODE, name: "가상청산소", kind: "clearing")
    @depository = Securities::Account.create!(code: Securities::Seed::DEPOSITORY_CODE, name: "가상예탁원", kind: "depository")
    @opening = Securities::Settlement.create!(settle_date: Date.new(2026, 10, 30), status: "settled",
                                              settled_at: Time.utc(2026, 10, 30, 7, 0, 0))
    @buyer = investor("VT-B", cash: 10_000_000)
    @seller = investor("VT-S", stocks: 100)
    [MON, TUE].each { |d| open_day(d) }
    @mon = KST.local(2026, 11, 2, 10, 0, 0)
    @tue = KST.local(2026, 11, 3, 10, 0, 0)
  end

  def investor(code, cash: 0, stocks: 0)
    account = Securities::Account.create!(code: code, name: "가상투자자 #{code}", kind: "investor")
    fund(account, @cash, cash)
    fund(account, @equity, stocks)
    account
  end

  def fund(account, asset, qty)
    return if qty.zero?

    Securities::LedgerEntry.create!(settlement: @opening, from_account: @depository, to_account: account, asset: asset,
                                    qty: qty, idem_key: "open:#{account.code}:#{asset.code}")
    Securities::Position.create!(account: account, asset: asset, qty: qty)
  end

  def open_day(date)
    Securities::Auction.create!(asset: @equity, trade_date: date, session: "open", mode: "sequential", qty: 0,
                                ran_at: KST.local(date.year, date.month, date.day, 9, 0, 0))
  end

  def place(account, side, qty:, price:, at: @mon)
    Securities::PlaceOrder.call(account: account, asset: @equity, side: side, order_type: "limit", qty: qty,
                                price: price, client_key: "k-#{SecureRandom.hex(4)}", at: at)
  end

  def trade(qty:, price:, at: @mon)
    place(@seller, "sell", qty: qty, price: price, at: at)
    place(@buyer, "buy", qty: qty, price: price, at: at)
  end

  def reconcile(as_of)
    Securities::Reconcile.call(as_of: as_of)
  end

  # 월요일 체결을 수요일에 결제한 정상 상태.
  def settled_state
    trade(qty: 3, price: 50_000)
    settle_wednesday
  end

  def settle_wednesday
    Securities::Settle.call(settle_date: WED, at: KST.local(2026, 11, 4, 16, 0, 0))
    assert_empty reconcile(WED), "정상 상태에서 대사가 비어 있지 않다"
  end

  test "정상: 개시 잔고만 있어도, 체결 후 결제 전에도, 결제 후에도 비어 있다" do
    assert_empty reconcile(MON)
    trade(qty: 3, price: 50_000)
    assert_empty reconcile(TUE)
    settle_wednesday
  end

  test "T5 positions 를 틀면 그 계좌 · 자산을 원장 합과 함께 보고한다" do
    settled_state
    Securities::Position.where(account_id: @buyer.id, asset_id: @equity.id).update_all(qty: 99)

    assert_equal [{ kind: :position_mismatch, account: "VT-B", asset: "VT-EQ", ledger: 3, position: 99 }], reconcile(WED)
  end

  test "T5 positions 행이 없어도 원장 합이 있으면 보고한다(없는 행은 0)" do
    settled_state
    Securities::Position.where(account_id: @seller.id, asset_id: @cash.id).delete_all

    assert_equal [{ kind: :position_mismatch, account: "VT-S", asset: "VKRW", ledger: 150_000, position: 0 }], reconcile(WED)
  end

  test "예탁은 대사에서 뺀다: 예탁 계좌는 원장 합이 음수여도 positions 가 없어도 정상이다" do
    settled_state
    ledger_net = Securities::LedgerEntry.where(from_account_id: @depository.id).sum(:qty)

    assert_operator ledger_net, :>, 0
    assert_empty reconcile(WED)
  end

  test "T5 결제일이 지났는데 결제되지 않은 체결을 보고한다(결제일 전에는 아니다)" do
    settled_state
    trade(qty: 1, price: 50_000, at: @tue) # 화요일 체결 → 목요일 결제
    execution = Securities::Execution.order(:id).last
    assert_equal [TUE, THU, nil], [execution.trade_date, execution.settle_date, execution.settlement_id]

    assert_empty reconcile(WED)
    assert_equal [{ kind: :overdue_unsettled, execution_id: execution.id, settle_date: THU }], reconcile(THU)
  end

  test "T5 끝난 주문의 열린 홀드를 보고한다" do
    settled_state
    resting = place(@seller, "sell", qty: 2, price: 60_000, at: @tue)
    hold = resting.hold
    assert_empty reconcile(WED)

    Securities::Order.where(id: resting.id).update_all(status: "cancelled") # CancelOrder 를 거치지 않아 홀드가 남는다

    assert_equal [{ kind: :open_hold_on_closed, hold_id: hold.id, order_id: resting.id, status: "cancelled", qty: 2 }],
                 reconcile(WED)
  end

  test "T5 청산 계좌의 자산별 합이 0 이 아니면 보고한다" do
    settled_state
    Securities::LedgerEntry.create!(settlement: @opening, from_account: @depository, to_account: @clearing,
                                    asset: @equity, qty: 5, idem_key: "stray")

    assert_equal [{ kind: :clearing_nonzero, account: "VCLR-001", asset: "VT-EQ", net: 5 }], reconcile(WED)
  end

  test "T5 reject_reason 없는 rejected 는 update_all 로 넣어도 DB 가 거부한다" do
    accepted = place(@seller, "sell", qty: 2, price: 60_000)
    assert_equal ["accepted", nil], [accepted.status, accepted.reject_reason]

    error = assert_raises(ActiveRecord::CheckViolation) do
      Securities::Record.transaction(requires_new: true) do
        Securities::Order.where(id: accepted.id).update_all(status: "rejected")
      end
    end

    assert_includes error.message, "orders_reject_reason_status_check"
    assert_equal "accepted", accepted.reload.status
  end
end
