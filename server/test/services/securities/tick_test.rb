require "test_helper"

# 호가 단위 · 가격제한. 구간 경계마다 경계 바로 아래/위를 한 건씩 본다.
class Securities::TickTest < ActiveSupport::TestCase
  # [가격, 단위]: 각 구간의 마지막 값과 다음 구간의 첫 값
  UNITS = [
    [1, 1], [1_999, 1], [2_000, 5], [4_999, 5], [5_000, 10], [19_999, 10], [20_000, 50],
    [49_999, 50], [50_000, 100], [199_999, 100], [200_000, 500], [499_999, 500], [500_000, 1_000],
    [2_000_000, 1_000]
  ].freeze

  test "구간 경계마다 단위가 바뀐다" do
    UNITS.each do |price, unit|
      assert_equal unit, Securities::Tick.unit(price), "#{price} 의 단위"
    end
  end

  test "단위의 배수만 유효하고 0 · 음수 · 정수가 아닌 값은 아니다" do
    assert Securities::Tick.valid?(50_100)
    refute Securities::Tick.valid?(50_050)
    assert Securities::Tick.valid?(34_950)
    refute Securities::Tick.valid?(2_001) # 2,000 이상은 5 단위
    assert Securities::Tick.valid?(1_999)
    refute Securities::Tick.valid?(0)
    refute Securities::Tick.valid?(-100)
    refute Securities::Tick.valid?(nil)
    refute Securities::Tick.valid?(100.0)
  end

  test "가격제한은 기준가 ±30% 이고 상한은 내림 하한은 올림이다" do
    assert_equal [35_000, 65_000], Securities::Tick.limits(50_000)
    assert_equal [50_400, 93_600], Securities::Tick.limits(72_000)
    assert_equal [2_100, 3_900], Securities::Tick.limits(3_000)
    # 상한 20,221.5→20,221 은 50 단위로 내려 20,200, 하한 10,888.5 는 10,889 에서 10 단위로 올려 10,890
    assert_equal [10_890, 20_200], Securities::Tick.limits(15_555)
    # 상한 5,203 은 10 단위로 내려 5,200, 하한 2,802.1 은 2,803 에서 5 단위로 올려 2,805
    assert_equal [2_805, 5_200], Securities::Tick.limits(4_003)
  end

  test "계산된 한계는 항상 유효한 호가다" do
    [1_000, 1_234, 4_003, 15_555, 72_000, 260_000, 610_000, 999_999].each do |base|
      lower, upper = Securities::Tick.limits(base)

      assert Securities::Tick.valid?(lower), "#{base} 하한 #{lower}"
      assert Securities::Tick.valid?(upper), "#{base} 상한 #{upper}"
      assert_operator lower, :>=, base * 70 / 100
      assert_operator upper, :<=, base * 130 / 100
    end
  end
end
