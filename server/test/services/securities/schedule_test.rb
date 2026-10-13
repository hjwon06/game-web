require "test_helper"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# roll! 만 골라 실패시키는 prepend. minitest 6 이라 stub 을 쓰지 않는다. on_date 가 nil 이면 그대로 통과한다.
module RollFailure
  class << self
    attr_accessor :on_date
  end

  def roll!(asset:, trade_date:)
    raise "roll 실패" if RollFailure.on_date == trade_date

    super
  end
end
Securities::BasePrice.singleton_class.prepend(RollFailure)

# random_end_at 을 그 거래일 08:30(settle 과 같은 시각)으로 모으는 prepend. armed 가 꺼져 있으면(기본) 그대로 통과한다.
# 같은 시각 순서 테스트만 켠다. 시각은 받은 trade_date 기준이라 날짜가 바뀌면 같이 바뀐다.
module PinnedRandomEnd
  class << self
    attr_accessor :armed
  end

  def random_end_at(**opts)
    return super unless PinnedRandomEnd.armed

    Securities::Clock.at_minute(opts.fetch(:trade_date), Securities::Phase::SCHEDULE.first[1])
  end
end
Securities::Auction.singleton_class.prepend(PinnedRandomEnd)

# 하루 일정(Schedule.events · run!). 체결은 실제 경로(PlaceOrder → Auction → Settle)로 만든다.
# 달력: 11-02(월) ~ 11-06(금) 영업, 11-07 · 11-08 휴장 행, 11-09(월) 영업. 기준가 50,000.
# 변이 검사(AC): roll! 빼기 → T2, 종가 세션 대신 그날 마지막 체결 → T3, settle 일정 빼기 → T5,
# 시각 대신 종류 순 정렬 → T1 · T6, 창을 닫힌 구간으로 → T1,
# 같은 시각 순서(종류 · id) 빼기 → T1 같은 시각 테스트(F2).
class Securities::ScheduleTest < ActiveSupport::TestCase
  KST = ActiveSupport::TimeZone["Asia/Seoul"]
  SEED = 7
  MON = Date.new(2026, 11, 2)
  TUE = Date.new(2026, 11, 3)
  WED = Date.new(2026, 11, 4)

  setup do
    @cash = Securities::Asset.create!(code: Securities::Asset::CASH_CODE, name: "가상원화", kind: "cash")
    @equity = Securities::Asset.create!(code: "VT-EQ", name: "가상종목", kind: "equity", base_price: 50_000)
    (2..6).each { |d| Securities::MarketDay.create!(trade_date: Date.new(2026, 11, d), business_day: true) }
    [7, 8].each { |d| Securities::MarketDay.create!(trade_date: Date.new(2026, 11, d), business_day: false) }
    Securities::MarketDay.create!(trade_date: Date.new(2026, 11, 9), business_day: true)
    @clearing = Securities::Account.create!(code: Securities::Seed::CLEARING_CODE, name: "가상청산소", kind: "clearing")
    @depository = Securities::Account.create!(code: Securities::Seed::DEPOSITORY_CODE, name: "가상예탁원", kind: "depository")
    @opening = Securities::Settlement.create!(settle_date: Date.new(2026, 10, 30), status: "settled",
                                              settled_at: Time.utc(2026, 10, 30, 7, 0, 0))
    @n = 0
  end

  teardown do
    RollFailure.on_date = nil
    PinnedRandomEnd.armed = false
  end

  def t(day, hour, min, sec = 0)
    KST.local(2026, 11, day, hour, min, sec)
  end

  # 계정을 새로 만들어 개시 잔고(원장 + positions)를 넣고 지정가 주문을 낸다.
  def place(side, qty:, price:, at:)
    account = Securities::Account.create!(code: "VT-#{@n += 1}", name: "가상투자자", kind: "investor")
    asset, amount = side == "buy" ? [@cash, 10_000_000] : [@equity, 100]
    Securities::LedgerEntry.create!(settlement: @opening, from_account: @depository, to_account: account, asset: asset,
                                    qty: amount, idem_key: "open:#{account.code}:#{asset.code}")
    Securities::Position.create!(account: account, asset: asset, qty: amount)
    Securities::PlaceOrder.call(account: account, asset: @equity, side: side, order_type: "limit", qty: qty,
                                price: price, client_key: "k-#{@n}", at: at)
  end

  def run!(from, to, **opts)
    Securities::Schedule.run!(from: from, to: to, seed: SEED, **opts)
  end

  def events(from, to)
    Securities::Schedule.events(from: from, to: to, seed: SEED)
  end

  def shape(list)
    list.map { |e| [e.kind, e.trade_date, e.asset&.id, e.at] }
  end

  def position(account_id, asset)
    Securities::Position.where(account_id: account_id, asset_id: asset.id).sum(:qty)
  end

  # 월요일 09:00 시가까지 돌려 접속매매를 연다.
  def open_monday
    run!(t(2, 0, 0), t(2, 9, 1))
  end

  def trade_intraday(price: 51_000, at: t(2, 10, 0))
    place("sell", qty: 1, price: price, at: at)
    place("buy", qty: 1, price: price, at: at)
  end

  test "T1 events: 하루 창은 settle 1 · open 5 · close 5 가 시각 순이고 반열림 [from, to) 이다" do
    4.times { |i| Securities::Asset.create!(code: "VT-X#{i}", name: "가상종목#{i}", kind: "equity", base_price: 50_000) }
    ids = Securities::Asset.where(kind: "equity").order(:id).ids

    day = events(t(2, 0, 0), t(3, 0, 0))

    assert_equal [:settle] + [:open] * 5 + [:close] * 5, day.map(&:kind)
    assert_equal t(2, 8, 30), day.first.at
    # 랜덤엔드는 종목마다 달라 종류 안의 순서는 [시각, 종목 id] 다. id 는 같은 시각일 때만 순서를 정한다.
    %w[open close].each do |session|
      group = day.select { |e| e.kind == session.to_sym }
      by_time_then_id = ids.sort_by do |id|
        [Securities::Auction.random_end_at(trade_date: MON, asset_id: id, session: session, seed: SEED).to_r, id]
      end
      assert_equal by_time_then_id, group.map { |e| e.asset.id }, "#{session}: 시각 순, 같은 시각이면 종목 id 순"
      assert_equal group.map(&:at).sort, group.map(&:at)
    end
    assert(day[1, 5].all? { |e| e.at >= t(2, 9, 0, 0) && e.at <= t(2, 9, 0, 30) })
    assert(day[6, 5].all? { |e| e.at >= t(2, 15, 30, 0) && e.at <= t(2, 15, 30, 30) })
    assert_equal day.map(&:at).sort, day.map(&:at)

    weekend = events(t(6, 15, 0), t(9, 9, 1))
    assert_equal [:close] * 5 + [:settle] + [:open] * 5, weekend.map(&:kind)
    assert_equal [Date.new(2026, 11, 6)] * 5 + [Date.new(2026, 11, 9)] * 6, weekend.map(&:trade_date)
    assert_empty events(t(7, 0, 0), t(9, 8, 30)), "휴장일에는 일정이 없다"
  end

  test "T1 같은 시각이면 settle → open → close, 그 안은 종목 id 순" do
    4.times { |i| Securities::Asset.create!(code: "VT-X#{i}", name: "가상종목#{i}", kind: "equity", base_price: 50_000) }
    ids = Securities::Asset.where(kind: "equity").order(:id).ids
    PinnedRandomEnd.armed = true

    day = events(t(2, 0, 0), t(3, 0, 0))

    assert_equal [:settle] + [:open] * 5 + [:close] * 5, day.map(&:kind)
    assert_equal [t(2, 8, 30)], day.map(&:at).uniq, "모든 일정이 같은 시각이다"
    assert_equal ids, day[1, 5].map { |e| e.asset.id }
    assert_equal ids, day[6, 5].map { |e| e.asset.id }
  end

  test "T1 같은 시각은 거래일마다 따로: 이틀 창은 날마다 settle → open × 5 → close × 5 가 날짜 순" do
    4.times { |i| Securities::Asset.create!(code: "VT-X#{i}", name: "가상종목#{i}", kind: "equity", base_price: 50_000) }
    ids = Securities::Asset.where(kind: "equity").order(:id).ids
    PinnedRandomEnd.armed = true

    two = events(t(2, 0, 0), t(4, 0, 0))

    assert_equal 22, two.size
    assert_equal ([:settle] + [:open] * 5 + [:close] * 5) * 2, two.map(&:kind)
    assert_equal [MON] * 11 + [TUE] * 11, two.map(&:trade_date)
    assert_equal [t(2, 8, 30)] * 11 + [t(3, 8, 30)] * 11, two.map(&:at)
    [two[0, 11], two[11, 11]].each do |day|
      assert_equal ids, day[1, 5].map { |e| e.asset.id }
      assert_equal ids, day[6, 5].map { |e| e.asset.id }
    end
  end

  test "T1 반열림: to 가 월 08:30 이면 월 settle 이 빠지고 from 이 월 08:30 인 다음 창에 들어간다" do
    first = events(t(6, 15, 0), t(9, 8, 30))
    second = events(t(9, 8, 30), t(9, 9, 1))

    assert_equal [:close], first.map(&:kind)
    assert_equal [:settle, :open], second.map(&:kind)
    assert_equal shape(events(t(6, 15, 0), t(9, 9, 1))), shape(first + second), "창을 이어 붙이면 겹치지도 빠지지도 않는다"
  end

  test "T2 run!: 시가 · 장중 · 종가 체결 뒤 기준가 = 종가 세션 마지막 체결가" do
    place("buy", qty: 2, price: 50_000, at: t(2, 8, 45))
    place("sell", qty: 2, price: 50_000, at: t(2, 8, 45))
    assert_equal [:settle, :open], open_monday.map(&:kind)
    trade_intraday
    place("buy", qty: 3, price: 49_000, at: t(2, 15, 25))
    place("sell", qty: 3, price: 49_000, at: t(2, 15, 25))

    ran = run!(t(2, 9, 1), t(2, 15, 31))

    assert_equal [:close], ran.map(&:kind)
    assert_equal [50_000, 51_000, 49_000], Securities::Execution.order(:id).pluck(:price)
    assert_equal 49_000, @equity.reload.base_price
  end

  test "T3 장중 체결은 있고 종가 세션 체결이 없으면 기준가 그대로" do
    open_monday
    trade_intraday

    run!(t(2, 9, 1), t(2, 15, 31))

    assert_equal [51_000], Securities::Execution.pluck(:price)
    assert_equal 50_000, @equity.reload.base_price
    assert_equal 0, Securities::Auction.find_by!(session: "close").qty
  end

  test "T4 끄기: 종가 세션 체결이 여러 가격이면 마지막(id 최대) 체결가" do
    open_monday
    place("sell", qty: 1, price: 48_000, at: t(2, 15, 25))
    place("sell", qty: 1, price: 49_000, at: t(2, 15, 25))
    place("buy", qty: 1, price: 50_000, at: t(2, 15, 25))
    place("buy", qty: 1, price: 50_000, at: t(2, 15, 25))

    run!(t(2, 9, 1), t(2, 15, 31), single_price: false)

    prices = Securities::Execution.order(:id).pluck(:price)
    assert_equal 2, prices.uniq.size
    assert_equal prices.last, @equity.reload.base_price
    assert_equal "sequential", Securities::Auction.find_by!(session: "close").mode
  end

  test "T5 결제: 월요일 체결은 수요일 08:30 settle 일정이 결제한다" do
    open_monday
    trade_intraday
    buy_order = Securities::Order.where(side: "buy").sole
    sell_order = Securities::Order.where(side: "sell").sole
    execution = Securities::Execution.sole
    assert_equal [MON, WED, nil], [execution.trade_date, execution.settle_date, execution.settlement_id]

    run!(t(2, 9, 1), t(4, 8, 30)) # 수요일 08:30 은 to 라 아직 안 돈다
    assert_nil execution.reload.settlement_id
    assert_equal ["settled"] * 2, Securities::Settlement.where(settle_date: [MON, TUE]).pluck(:status)

    ran = run!(t(4, 8, 30), t(4, 8, 31))

    assert_equal [:settle], ran.map(&:kind)
    settlement = Securities::Settlement.find_by!(settle_date: WED)
    assert_equal [settlement.id, t(4, 8, 30)], [execution.reload.settlement_id, settlement.settled_at]
    assert_equal [1, 9_949_000], [position(buy_order.account_id, @equity), position(buy_order.account_id, @cash)]
    assert_equal [99, 51_000], [position(sell_order.account_id, @equity), position(sell_order.account_id, @cash)]
    assert_empty Securities::Reconcile.call(as_of: WED)
  end

  test "T6 멱등 · 순서: 이틀 창을 두 번 돌려도 같고 월 close 가 화 open 보다 먼저 돈다" do
    open_monday
    leftover = place("sell", qty: 1, price: 55_000, at: t(2, 10, 0)) # 월요일에 안 팔린 매도
    place("buy", qty: 1, price: 49_000, at: t(2, 15, 25))
    place("sell", qty: 1, price: 49_000, at: t(2, 15, 25))

    first = run!(t(2, 0, 0), t(4, 0, 0))
    after = counts
    second = run!(t(2, 0, 0), t(4, 0, 0))

    assert_equal first.map(&:at).sort, first.map(&:at), "일정은 시각 순으로 돈다"
    assert_equal after, counts
    assert_equal 49_000, @equity.reload.base_price
    assert_equal shape(first), shape(second), "두 번째 실행도 같은 일정을 돈다"
    assert_equal "cancelled", leftover.reload.status
    mon_close = Securities::Auction.find_by!(trade_date: MON, session: "close")
    tue_open = Securities::Auction.find_by!(trade_date: TUE, session: "open")
    assert_operator mon_close.ran_at, :<, tue_open.ran_at
    assert_equal [0, 0], [tue_open.qty, tue_open.price.to_i]
    # 월 15:25 쌍은 월요일 종가에서 월요일 거래일로 체결됐고 화 시가에 섞이지 않았다.
    assert_equal [[MON, mon_close.ran_at]], Securities::Execution.pluck(:trade_date, :executed_at)
  end

  test "T6 일정 하나가 자기 트랜잭션: 화 close 의 roll! 이 실패해도 월 일정은 남고 다시 돌리면 맞춰진다" do
    open_monday
    place("buy", qty: 1, price: 49_000, at: t(2, 15, 25))
    place("sell", qty: 1, price: 49_000, at: t(2, 15, 25))
    RollFailure.on_date = TUE

    assert_raises(RuntimeError) { run!(t(2, 9, 1), t(4, 0, 0)) }

    assert_equal 49_000, @equity.reload.base_price, "월 close · roll! 은 이미 커밋됐다"
    assert_not Securities::Auction.exists?(trade_date: TUE, session: "close"), "화 close 는 roll! 과 함께 되돌아간다"
    RollFailure.on_date = nil

    assert_equal [:close], run!(t(2, 9, 1), t(4, 0, 0)).select { |e| e.trade_date == TUE && e.kind == :close }.map(&:kind)
    assert Securities::Auction.exists?(trade_date: TUE, session: "close")
  end

  def counts
    [Securities::Auction.count, Securities::Settlement.count, Securities::Execution.count, @equity.reload.base_price]
  end
end
