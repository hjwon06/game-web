# 호가 단위와 가격제한. 시뮬레이터 규칙이다(거래소 원문은 확인하지 않았다).
# 가격 구간(미만)별 단위: 2,000 → 1 · 5,000 → 5 · 20,000 → 10 · 50,000 → 50 · 200,000 → 100 · 500,000 → 500 · 그 이상 1,000.
# 구간 경계는 모두 더 큰 쪽 단위의 배수라 "단위로 내림/올림" 해도 구간을 벗어나지 않는다.
# 가격제한은 기준가 ±30% 이고 상한은 그 가격대 단위로 내림, 하한은 올림이다. 전부 정수 연산이다.
module Securities
  module Tick
    BANDS = [[2_000, 1], [5_000, 5], [20_000, 10], [50_000, 50], [200_000, 100], [500_000, 500]].freeze
    TOP_UNIT = 1_000
    LIMIT_PERCENT = 30

    module_function

    def unit(price)
      BANDS.each { |under, step| return step if price < under }
      TOP_UNIT
    end

    def valid?(price)
      price.is_a?(Integer) && price.positive? && (price % unit(price)).zero?
    end

    # [하한, 상한]. 기준가 기준이다.
    def limits(base_price)
      upper = base_price * (100 + LIMIT_PERCENT) / 100
      lower = (base_price * (100 - LIMIT_PERCENT) + 99) / 100
      [ceil_to_unit(lower), floor_to_unit(upper)]
    end

    def floor_to_unit(price)
      price - (price % unit(price))
    end

    def ceil_to_unit(price)
      step = unit(price)
      price + ((step - (price % step)) % step)
    end
  end
end
