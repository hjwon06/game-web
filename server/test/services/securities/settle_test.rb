require "test_helper"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# D+2 결제(Settle). 체결은 직접 넣지 않고 실제 경로(PlaceOrder → Match → Fill)로 만든다 — 체결 행의 모양을 흉내 내지 않는다.
# 달력은 11-02(월) ~ 11-06(금), 기준가 50,000. 월요일 체결의 결제일은 수요일(11-04)이다.
# 개시 잔고는 원장(예탁 → 투자자)과 positions 를 같이 만든다. Reconcile 이 "원장 합 = positions" 를 보기 때문이다.
class Securities::SettleTest < ActiveSupport::TestCase
  KST = ActiveSupport::TimeZone["Asia/Seoul"]
  MON = Date.new(2026, 11, 2)
  TUE = Date.new(2026, 11, 3)
  WED = Date.new(2026, 11, 4)

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
    @wed_close = KST.local(2026, 11, 4, 16, 0, 0)
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

  # 시작 문: 그날 시가 행이 있어야 접수가 Match 를 부른다.
  def open_day(date)
    Securities::Auction.create!(asset: @equity, trade_date: date, session: "open", mode: "sequential", qty: 0,
                                ran_at: KST.local(date.year, date.month, date.day, 9, 0, 0))
  end

  def place(account, side, qty:, price:, at: @mon)
    Securities::PlaceOrder.call(account: account, asset: @equity, side: side, order_type: "limit", qty: qty,
                                price: price, client_key: "k-#{SecureRandom.hex(4)}", at: at)
  end

  # 먼저 낸 쪽(maker)의 가격으로 체결된다.
  def trade(buyer, seller, qty:, price:, at: @mon)
    place(seller, "sell", qty: qty, price: price, at: at)
    place(buyer, "buy", qty: qty, price: price, at: at)
  end

  def settle(date = WED, at: @wed_close)
    Securities::Settle.call(settle_date: date, at: at)
  end

  def qty(account, asset)
    Securities::Position.where(account_id: account.id, asset_id: asset.id).sum(:qty)
  end

  def ledger(settlement)
    codes = Securities::Account.pluck(:id, :code).to_h
    assets = Securities::Asset.pluck(:id, :code).to_h
    Securities::LedgerEntry.where(settlement_id: settlement.id).map do |e|
      [e.idem_key, codes[e.from_account_id], codes[e.to_account_id], assets[e.asset_id], e.qty]
    end
  end

  def clearing_sum(asset)
    in_sum = Securities::LedgerEntry.where(to_account_id: @clearing.id, asset_id: asset.id).sum(:qty)
    in_sum - Securities::LedgerEntry.where(from_account_id: @clearing.id, asset_id: asset.id).sum(:qty)
  end

  test "T1 월요일 체결은 수요일에 결제된다: positions · 원장(투자자 ↔ 청산) · settlement_id · settled · 대사 정상" do
    trade(@buyer, @seller, qty: 3, price: 50_000)
    execution = Securities::Execution.sole
    assert_equal [MON, WED, nil], [execution.trade_date, execution.settle_date, execution.settlement_id]
    assert_empty Securities::Reconcile.call(as_of: TUE), "결제일 전에는 어긋남이 없어야 한다"

    settlement = settle

    assert_equal ["settled", WED, @wed_close], [settlement.status, settlement.settle_date, settlement.settled_at]
    assert_equal settlement.id, execution.reload.settlement_id
    assert_equal [3, 9_850_000], [qty(@buyer, @equity), qty(@buyer, @cash)]
    assert_equal [97, 150_000], [qty(@seller, @equity), qty(@seller, @cash)]
    assert_equal [
      ["settle:2026-11-04:VT-B:VKRW", "VT-B", "VCLR-001", "VKRW", 150_000],
      ["settle:2026-11-04:VT-B:VT-EQ", "VCLR-001", "VT-B", "VT-EQ", 3],
      ["settle:2026-11-04:VT-S:VKRW", "VCLR-001", "VT-S", "VKRW", 150_000],
      ["settle:2026-11-04:VT-S:VT-EQ", "VT-S", "VCLR-001", "VT-EQ", 3]
    ].sort, ledger(settlement).sort
    assert_equal [0, 0], [clearing_sum(@cash), clearing_sum(@equity)]
    assert_empty Securities::Reconcile.call(as_of: WED)
  end

  test "T1 체결이 없는 월요일 결제는 원장 · positions 를 바꾸지 않고 settled 행만 남긴다" do
    trade(@buyer, @seller, qty: 3, price: 50_000)
    before = [Securities::LedgerEntry.count, Securities::Position.order(:id).pluck(:account_id, :asset_id, :qty)]

    settlement = settle(MON, at: KST.local(2026, 11, 2, 16, 0, 0))

    assert_equal ["settled", MON], [settlement.status, settlement.settle_date]
    assert_empty ledger(settlement)
    assert_equal before, [Securities::LedgerEntry.count, Securities::Position.order(:id).pluck(:account_id, :asset_id, :qty)]
    assert_nil Securities::Execution.sole.settlement_id, "월요일 결제가 수요일 체결을 묶으면 안 된다"
  end

  test "그날 결제분만 묶는다: 화요일 체결(목요일 결제)은 수요일 결제에서 남는다" do
    trade(@buyer, @seller, qty: 3, price: 50_000)
    trade(@buyer, @seller, qty: 1, price: 50_000, at: @tue)

    settle

    by_date = Securities::Execution.order(:settle_date).map { |e| [e.settle_date, e.settlement_id.nil?] }
    assert_equal [[WED, false], [Date.new(2026, 11, 5), true]], by_date
    assert_equal 3, qty(@buyer, @equity)
  end

  test "T2 같은 투자자가 같은 날 같은 종목을 사고 팔면 주식 원장 행이 없고 현금은 차액 한 행이다" do
    trader = investor("VT-X", cash: 1_000_000)
    other_seller = investor("VT-Y", stocks: 10)
    other_buyer = investor("VT-Z", cash: 1_000_000)
    trade(trader, other_seller, qty: 3, price: 50_000)          # 150,000 지급, 주식 +3
    trade(other_buyer, trader, qty: 3, price: 51_000)           # 153,000 수취, 주식 −3
    assert_equal 2, Securities::Execution.count

    settlement = settle

    rows = ledger(settlement)
    mine = rows.select { |key, *| key.include?(":VT-X:") }
    assert_equal [["settle:2026-11-04:VT-X:VKRW", "VCLR-001", "VT-X", "VKRW", 3_000]], mine
    assert_equal 5, rows.size, "X 현금 1 + Y 현금 · 주식 2 + Z 현금 · 주식 2"
    assert_equal 0, qty(trader, @equity)
    assert_equal 1_003_000, qty(trader, @cash)
    assert_equal [7, 150_000], [qty(other_seller, @equity), qty(other_seller, @cash)]
    assert_equal [3, 847_000], [qty(other_buyer, @equity), qty(other_buyer, @cash)]
    assert_empty Securities::Reconcile.call(as_of: WED)
  end

  test "T3 두 번 불러도 settlements · 원장 · positions · settled_at 은 그대로다" do
    trade(@buyer, @seller, qty: 3, price: 50_000)
    first = settle
    snapshot = lambda do
      [Securities::Settlement.count, Securities::LedgerEntry.count,
       Securities::Position.order(:id).pluck(:account_id, :asset_id, :qty),
       Securities::Execution.order(:id).pluck(:settlement_id)]
    end
    before = snapshot.call

    again = settle(WED, at: @wed_close + 3600)

    assert_equal first.id, again.id
    assert_equal @wed_close, again.reload.settled_at, "두 번째 호출이 settled_at 을 덮어쓰면 안 된다"
    assert_equal before, snapshot.call
  end

  test "T4 결제 전후 각 계좌 · 자산의 가능 수량은 같다(미결제 몫이 positions 로 옮겨갈 뿐이다)" do
    trade(@buyer, @seller, qty: 3, price: 50_000)
    place(@seller, "sell", qty: 5, price: 60_000) # 열린 홀드 5
    pairs = [@buyer, @seller].product([@cash, @equity])
    available = -> { pairs.map { |account, asset| Securities::Available.for(account, asset) } }

    before = available.call
    settle

    assert_equal [9_850_000, 3, 150_000, 92], before
    assert_equal before, available.call
  end

  test "결제일 전에는 결제할 수 없다 — 행도 남기지 않는다" do
    trade(@buyer, @seller, qty: 3, price: 50_000)

    assert_raises(ArgumentError) { Securities::Settle.call(settle_date: WED, at: @tue) }
    assert_equal 0, Securities::Settlement.where(settle_date: WED).count
  end

  test "positions 가 음수가 되는 결제는 전부 되돌아간다(원장 · settlement_id · settlements)" do
    trade(@buyer, @seller, qty: 3, price: 50_000)
    Securities::Position.where(account_id: @buyer.id, asset_id: @cash.id).update_all(qty: 1) # 개시 잔고를 틀어 음수를 만든다
    ledger_count = Securities::LedgerEntry.count

    assert_raises(ActiveRecord::StatementInvalid) { settle }

    assert_equal ledger_count, Securities::LedgerEntry.count
    assert_equal 0, Securities::Settlement.where(settle_date: WED).count
    assert_nil Securities::Execution.sole.settlement_id
  end
end
