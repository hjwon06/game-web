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

  test "달력이 모자라면 추측하지 않고 예외를 낸다" do
    assert_raises(Securities::Calendar::Missing) { Securities::Calendar.settle_date(FRI + 3) } # 뒤에 영업일 1개뿐
    assert_raises(Securities::Calendar::Missing) { Securities::Calendar.next_business_day(FRI + 4) }
  end
end
