require "test_helper"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# 가상 시계. 기본값(speed 12 · night 5분)은 config/securities_clock.yml 에서 읽히므로 인자 없이 부른 단언이 그 파일을 확인한다.
# 달력: 11-06(금) 영업, 토 · 일 휴장, 11-09(월) · 11-10(화) 영업.
class Securities::ClockTest < ActiveSupport::TestCase
  KST = ActiveSupport::TimeZone["Asia/Seoul"]
  FRI = Date.new(2026, 11, 6)
  START = Time.utc(2026, 1, 1, 0, 0, 0)

  setup do
    { FRI => true, FRI + 1 => false, FRI + 2 => false, FRI + 3 => true, FRI + 4 => true }.each do |date, business|
      Securities::MarketDay.create!(trade_date: date, business_day: business)
    end
  end

  def at(minutes, seconds = 0, **opts)
    Securities::Clock.market_time(START + minutes * 60 + seconds, started_at: START, first_day: FRI, **opts)
  end

  def kst(day, hour, min, sec = 0)
    KST.local(day.year, day.month, day.day, hour, min, sec)
  end

  test "T1 장 구간: 0분 08:30 · 2분 30초 09:00 · 34분 59초 15:29:48 · 35분 15:30" do
    assert_equal kst(FRI, 8, 30), at(0)
    assert_equal kst(FRI, 9, 0), at(2, 30)
    assert_equal kst(FRI, 15, 29, 48), at(34, 59)
    assert_equal kst(FRI, 15, 30), at(35)
  end

  test "T1 밤 구간: 금요일 밤은 월요일 아침까지 고르게 흐르고 40분에 월요일 08:30" do
    assert_equal kst(FRI + 3, 8, 30), at(40)
    assert_equal kst(FRI + 2, 0, 0), at(37, 30) # 금 15:30 ~ 월 08:30(65시간)의 한가운데 = 일요일 00:00
  end

  test "둘째 영업일 장도 같은 속도로 흐른다(휴장일은 건너뛴다)" do
    assert_equal kst(FRI + 3, 9, 0), at(42, 30)
    assert_equal kst(FRI + 3, 15, 30), at(75)
  end

  test "T1 speed 를 인자로 덮어쓰면 장이 70분이 되고 35분에 12:00 이다" do
    assert_equal kst(FRI, 12, 0), at(35, speed: 6)
    assert_equal kst(FRI, 15, 30), at(70, speed: 6)
  end

  test "night_minutes 를 인자로 덮어쓴다" do
    assert_equal kst(FRI + 3, 8, 30), at(37, night_minutes: 2)
  end

  test "first_day 가 영업일이 아니거나 real_at 이 started_at 보다 이르면 ArgumentError" do
    assert_raises(ArgumentError) do
      Securities::Clock.market_time(START, started_at: START, first_day: FRI + 1)
    end
    assert_raises(ArgumentError) do
      Securities::Clock.market_time(START - 1, started_at: START, first_day: FRI)
    end
    assert_raises(ArgumentError) { at(0, speed: 0) }
  end

  test "달력이 모자라면 Calendar::Missing 이다" do
    assert_raises(Securities::Calendar::Missing) { at(200) } # 셋째 영업일 이후는 달력에 없다
  end
end
