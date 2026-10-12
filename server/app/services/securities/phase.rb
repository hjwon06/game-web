# 장 단계. 시뮬레이터 규칙이다(거래소 원문은 확인하지 않았다). 시각은 Asia/Seoul 기준이고 구간은 [시작, 끝) 이다.
# pre_open 08:30~09:00 · continuous 09:00~15:20 · closing 15:20~15:30 · 그 밖은 closed.
# market_days 에 그 날짜가 없거나 business_day 가 false 면 시각과 무관하게 closed 다.
module Securities
  module Phase
    ZONE = "Asia/Seoul".freeze
    # [단계, 시작 분(자정 기준), 끝 분]
    SCHEDULE = [
      [:pre_open, 8 * 60 + 30, 9 * 60],
      [:continuous, 9 * 60, 15 * 60 + 20],
      [:closing, 15 * 60 + 20, 15 * 60 + 30]
    ].freeze

    module_function

    def at(time)
      local = time.in_time_zone(ZONE)
      return :closed unless MarketDay.where(trade_date: local.to_date, business_day: true).exists?

      minute = local.hour * 60 + local.min
      SCHEDULE.each { |name, from, to| return name if minute >= from && minute < to }
      :closed
    end
  end
end
