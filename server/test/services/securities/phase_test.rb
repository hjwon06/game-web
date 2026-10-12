require "test_helper"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# 장 단계. 구간 경계마다 1건. 시각은 Asia/Seoul 이다.
class Securities::PhaseTest < ActiveSupport::TestCase
  KST = ActiveSupport::TimeZone["Asia/Seoul"]
  MONDAY = Date.new(2026, 11, 2)
  SATURDAY = Date.new(2026, 11, 7)
  UNLISTED_MONDAY = Date.new(2026, 11, 9)

  setup do
    Securities::MarketDay.create!(trade_date: MONDAY, business_day: true)
    Securities::MarketDay.create!(trade_date: SATURDAY, business_day: false)
  end

  def at(date, hour, min, sec = 0)
    KST.local(date.year, date.month, date.day, hour, min, sec)
  end

  test "구간 경계: [시작, 끝) 이다" do
    {
      [8, 29, 59] => :closed, [8, 30, 0] => :pre_open, [8, 59, 59] => :pre_open,
      [9, 0, 0] => :continuous, [15, 19, 59] => :continuous,
      [15, 20, 0] => :closing, [15, 29, 59] => :closing, [15, 30, 0] => :closed,
      [0, 0, 0] => :closed, [23, 59, 59] => :closed
    }.each do |(h, m, s), expected|
      assert_equal expected, Securities::Phase.at(at(MONDAY, h, m, s)), format("%02d:%02d:%02d", h, m, s)
    end
  end

  test "토요일(business_day false)은 장 시간이어도 closed 다" do
    assert_equal :closed, Securities::Phase.at(at(SATURDAY, 10, 0))
  end

  test "market_days 에 없는 날짜는 closed 다" do
    assert_equal :closed, Securities::Phase.at(at(UNLISTED_MONDAY, 10, 0))
  end

  test "UTC 로 들어와도 서울 시각으로 판정한다(UTC 일요일 23:30 = 서울 월요일 08:30)" do
    assert_equal :pre_open, Securities::Phase.at(Time.utc(2026, 11, 1, 23, 30, 0))
    assert_equal :continuous, Securities::Phase.at(Time.utc(2026, 11, 2, 0, 0, 0))
    assert_equal :closed, Securities::Phase.at(Time.utc(2026, 11, 2, 6, 30, 0)) # 서울 15:30
  end
end
