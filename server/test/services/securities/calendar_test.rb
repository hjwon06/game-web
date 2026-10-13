require "test_helper"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# 영업일 계산. 달력 입력은 2026-11-06(금)부터 11-10(화)까지다.
class Securities::CalendarTest < ActiveSupport::TestCase
  FRI = Date.new(2026, 11, 6)

  def days(spec)
    spec.each { |date, business| Securities::MarketDay.create!(trade_date: date, business_day: business) }
  end

  setup do
    days(FRI => true, FRI + 1 => false, FRI + 2 => false, FRI + 3 => true, FRI + 4 => true)
  end

  test "T1 다음 영업일: 금요일 → 월요일" do
    assert_equal FRI + 3, Securities::Calendar.next_business_day(FRI)
    assert_equal FRI + 3, Securities::Calendar.next_business_day(FRI + 1) # 토요일에서도 월요일
  end

  test "T1 결제일: 금요일 체결 → 화요일(영업일 +2)" do
    assert_equal FRI + 4, Securities::Calendar.settle_date(FRI)
  end

  test "공휴일(business_day false)인 평일은 세지 않는다" do
    Securities::MarketDay.where(trade_date: FRI + 3).update_all(business_day: false) # 월요일을 휴장으로
    days(FRI + 5 => true)

    assert_equal FRI + 4, Securities::Calendar.next_business_day(FRI)
    assert_equal FRI + 5, Securities::Calendar.settle_date(FRI)
  end

  test "T1 영업일 규칙: 월~금만 true, 토 · 일은 false" do
    week = (Date.new(2026, 11, 2)..Date.new(2026, 11, 8)).map { |d| Securities::Seed.business_day?(d) }

    assert_equal [true, true, true, true, true, false, false], week
  end

  test "T1 extend!: 첫 장부터 through 까지 규칙대로 채우고 두 번 돌려도 같은 행이다" do
    through = Date.new(2026, 12, 20)
    Securities::Calendar.extend!(through: through)
    first = Securities::MarketDay.order(:trade_date).pluck(:trade_date, :business_day)
    Securities::Calendar.extend!(through: through)

    assert_equal first, Securities::MarketDay.order(:trade_date).pluck(:trade_date, :business_day)
    assert_equal Securities::Seed::FIRST_MARKET_DAY, first.first.first
    assert_equal through, first.last.first
    assert_equal (Securities::Seed::FIRST_MARKET_DAY..through).count, first.size
    assert(first.all? { |date, business| business == Securities::Seed.business_day?(date) })
  end

  test "T1 extend!: 있는 행은 그대로다(휴장으로 고친 평일을 되돌리지 않는다)" do
    Securities::MarketDay.where(trade_date: FRI + 3).update_all(business_day: false) # 월요일 휴장
    Securities::Calendar.extend!(through: FRI + 10)

    assert_not Securities::MarketDay.find(FRI + 3).business_day
    assert_equal FRI + 10, Securities::MarketDay.maximum(:trade_date)
  end

  test "달력이 모자라면 추측하지 않고 예외를 낸다" do
    assert_raises(Securities::Calendar::Missing) { Securities::Calendar.settle_date(FRI + 3) } # 뒤에 영업일 1개뿐
    assert_raises(Securities::Calendar::Missing) { Securities::Calendar.next_business_day(FRI + 4) }
  end
end
