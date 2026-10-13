# 가상 시계. 현실 시각을 가상 시장 시각(Asia/Seoul)으로 바꾼다. 시뮬레이터 규칙이다.
# 하루 = 장(Phase::SCHEDULE 처음 시작 ~ 끝 구간을 speed 배로, 기본 07시간 ÷ 12 = 35분) + 밤(night_minutes, 기본 5분).
# 밤은 그날 장 마감 → 다음 영업일 장 시작을 고르게 흘린다. 휴장일은 Calendar 가 건너뛰므로 금요일 밤은 월요일 아침까지다.
# 계산은 전부 Rational 이다. 부동소수점 오차로 15:29:48 이 15:29:47.999 가 되지 않는다.
module Securities
  module Clock
    CONFIG_PATH = Rails.root.join("config", "securities_clock.yml").freeze
    ZONE = ActiveSupport::TimeZone[Phase::ZONE]

    module_function

    def defaults
      @defaults ||= YAML.safe_load_file(CONFIG_PATH).slice("speed", "night_minutes").freeze
    end

    def market_time(real_at, started_at:, first_day:, speed: nil, night_minutes: nil)
      speed ||= defaults.fetch("speed")
      night_minutes ||= defaults.fetch("night_minutes")
      validate!(speed, night_minutes, first_day)

      elapsed = real_at.to_r - started_at.to_r
      raise ArgumentError, "real_at 이 started_at 보다 이르다" if elapsed.negative?

      open_minute = Phase::SCHEDULE.first[1]
      close_minute = Phase::SCHEDULE.last[2]
      market_real = Rational((close_minute - open_minute) * 60, speed)
      night_real = night_minutes * 60

      index, within = elapsed.divmod(market_real + night_real)
      # 장 시간이면 그날 하나만 읽는다. 달력의 마지막 영업일 장중에 다음 날이 없다고 Missing 이 나면 안 된다.
      if within < market_real
        today = Calendar.days_from(first_day, offset: index, count: 1).first
        return at_minute(today, open_minute) + within * speed
      end

      today, next_day = Calendar.days_from(first_day, offset: index, count: 2)
      closes = at_minute(today, close_minute)
      night_span = at_minute(next_day, open_minute).to_r - closes.to_r
      closes + night_span * (within - market_real) / night_real
    end

    def validate!(speed, night_minutes, first_day)
      raise ArgumentError, "speed 는 양의 정수" unless speed.is_a?(Integer) && speed.positive?
      raise ArgumentError, "night_minutes 는 양의 정수" unless night_minutes.is_a?(Integer) && night_minutes.positive?
      return if MarketDay.exists?(trade_date: first_day, business_day: true)

      raise ArgumentError, "first_day #{first_day} 는 영업일이 아니다"
    end

    def at_minute(date, minute)
      ZONE.local(date.year, date.month, date.day, minute / 60, minute % 60)
    end
  end
end
