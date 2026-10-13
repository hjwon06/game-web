# 영업일 계산. 시뮬레이터 규칙이다(거래소 원문은 확인하지 않았다).
# market_days 에서 business_day 가 true 인 날만 센다. 달력이 모자라면 추측하지 않고 예외를 낸다.
# 결제일 = 체결일 다음 영업일부터 세어 2번째 영업일(T+2). 금요일 체결은 화요일이다.
module Securities
  module Calendar
    SETTLE_LAG = 2

    class Missing < StandardError; end

    module_function

    # date 다음(date 자신 제외) 첫 영업일.
    def next_business_day(date)
      days_from(date + 1, offset: 0, count: 1).first
    end

    def settle_date(trade_date)
      days_from(trade_date + 1, offset: SETTLE_LAG - 1, count: 1).first
    end

    # date 이상(자신 포함)의 영업일을 offset 번째부터 count 개. Clock 이 "n 번째 영업일과 그 다음 날"을 읽는 데 쓴다.
    def days_from(date, offset:, count:)
      days = MarketDay.where(business_day: true).where("trade_date >= ?", date)
                      .order(:trade_date).offset(offset).limit(count).pluck(:trade_date)
      raise Missing, "#{date} 이후 영업일 #{offset + count}개가 달력에 없다" if days.size < count

      days
    end
  end
end
