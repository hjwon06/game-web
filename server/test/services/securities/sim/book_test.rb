require "test_helper"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# 아침 장부(Sim::Book). 체결 · 시드만 읽고, 실제 경로(PlaceOrder · Schedule)로 만든 DB 와 Available · assets.base_price 를 비교한다.
# 변이 검사(AC): Book 을 지금 Available 로 만들면 T2(다시 불러도 같다 · 체결일 < date), 산 쪽 부호를 뒤집으면 T1,
# base 를 시드 기준가로만 두면 T1 · T2 가 실패해야 한다.
class Securities::Sim::BookTest < ActiveSupport::TestCase
  KST = ActiveSupport::TimeZone["Asia/Seoul"]
  SEED = Securities::Sim::Config::SEED
  MON = Date.new(2026, 11, 2)
  TUE = Date.new(2026, 11, 3)
  Book = Securities::Sim::Book
  Intents = Securities::Sim::Intents

  setup do
    Securities::Seed.run!(seed: SEED)
  end

  def book(date)
    Book.as_of(date: date, seed: SEED)
  end

  def opening
    Book.opening(plan: Securities::Seed.plan(seed: SEED))
  end

  def sliced(only)
    lambda do |date:, seed:, book:|
      only.include?(date) ? Intents.for_day(date: date, seed: seed, book: book).each_slice(5).map(&:first) : []
    end
  end

  def run(only, from, to)
    Securities::Sim::Runner.new(seed: SEED, single_price: true, intents: sliced(only)).advance(from: from, to: to)
  end

  test "T1 체결 하나: 산 쪽 보유 +qty · 현금 −금액, 판 쪽은 반대, base 는 마지막 체결가, 체결일 이전 날은 시드 그대로" do
    asset = Securities::Asset.find_by!(code: "VELEC")
    seller = Securities::Position.where(asset_id: asset.id).where("qty >= 2").order(:id).first.account
    buyer = Securities::Account.where(kind: "investor").where.not(id: seller.id).order(:id).first
    Securities::Auction.open!(asset: asset, trade_date: MON, at: KST.local(2026, 11, 2, 9, 0, 0))
    at = KST.local(2026, 11, 2, 10, 0, 0)
    Securities::PlaceOrder.call(account: seller, asset: asset, side: "sell", order_type: "limit", qty: 2, price: 73_000,
                                client_key: "b1-sell", at: at)
    Securities::PlaceOrder.call(account: buyer, asset: asset, side: "buy", order_type: "limit", qty: 2, price: 73_000,
                                client_key: "b1-buy", at: at)
    assert_equal 1, Securities::Execution.count, "체결이 있어야 이 테스트가 의미가 있다"

    seed_book = opening
    after = book(TUE)
    key = ->(account) { [account.code, "VELEC"] }

    assert_equal seed_book.holdings[key.call(seller)] - 2, after.holdings[key.call(seller)]
    assert_equal seed_book.holdings[key.call(buyer)] + 2, after.holdings[key.call(buyer)]
    assert_equal seed_book.cash[seller.code] + 146_000, after.cash[seller.code]
    assert_equal seed_book.cash[buyer.code] - 146_000, after.cash[buyer.code]
    assert_equal 73_000, after.base["VELEC"]
    assert_equal seed_book.base.except("VELEC"), after.base.except("VELEC"), "체결이 없는 종목은 시드 기준가"

    same_day = book(MON) # 체결일 < date 라 그날 체결은 아직 없다
    assert_equal seed_book.holdings, same_day.holdings
    assert_equal seed_book.cash, same_day.cash
    assert_equal seed_book.base, same_day.base
  end

  test "T2 아침 잔고: 다음 영업일 08:30 결제 직후 · 첫 주문 전 투자자 전부 × 종목이 Available.for · assets.base_price 와 같다" do
    from = KST.local(2026, 11, 2, 0, 0, 0)
    run([MON], from, KST.local(2026, 11, 3, 8, 31, 0)) # 화 의도는 비운 공급자: 08:30 결제 뒤 · 첫 주문 전에서 멈춘다
    assert_operator Securities::Execution.count, :>=, 1, "체결이 없으면 시드 잔고와 같아 의미가 없다"
    assert_equal 1, Securities::Settlement.where(settle_date: TUE, status: "settled").count, "화 08:30 결제가 끝났다"

    morning = book(TUE)
    cash = Securities::Asset.find_by!(code: Securities::Asset::CASH_CODE)
    equities = Securities::Asset.where(kind: "equity").order(:id).to_a
    investors = Securities::Account.where(kind: "investor").order(:id).to_a

    assert_not_equal opening.holdings, morning.holdings
    assert_equal investors.size * equities.size, morning.holdings.size
    investors.each do |account|
      assert_equal Securities::Available.for(account, cash), morning.cash.fetch(account.code), "#{account.code} 현금"
      equities.each do |asset|
        assert_equal Securities::Available.for(account, asset), morning.holdings.fetch([account.code, asset.code]),
                     "#{account.code} #{asset.code} 보유"
      end
    end
    equities.each { |asset| assert_equal asset.reload.base_price, morning.base.fetch(asset.code), "#{asset.code} 기준가" }
    assert_operator equities.count { |a| a.base_price != opening.base.fetch(a.code) }, :>=, 1, "기준가가 시드에서 움직였다"
  end

  test "T2 그날을 다 돌린 뒤 다시 불러도 같다(화 장부는 화 체결 · 주문에 영향받지 않는다)" do
    run([MON], KST.local(2026, 11, 2, 0, 0, 0), KST.local(2026, 11, 3, 8, 31, 0))
    before = book(TUE)

    run([TUE], KST.local(2026, 11, 3, 8, 31, 0), KST.local(2026, 11, 4, 0, 0, 0))
    assert_operator Securities::Execution.where(trade_date: TUE).count, :>=, 1, "화 체결이 있어야 한다"
    after = book(TUE)

    assert_equal before.holdings, after.holdings
    assert_equal before.cash, after.cash
    assert_equal before.base, after.base
    assert_not_equal before.cash, book(Date.new(2026, 11, 4)).cash, "수요일 장부는 화 체결을 반영한다"
  end
end
