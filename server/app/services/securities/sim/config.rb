# 투자자 봇 · 진행기 숫자. 시뮬레이터 규칙이다(거래소 원문은 확인하지 않았다). 숫자는 여기 한 곳에만 둔다.
#   - ORDERS_PER_DAY: 영업일 하루 의도 수. PRE_OPEN_SHARE 만큼은 08:30~09:00 지정가, 나머지는 09:00~15:30.
#   - MARKET_SHARE: 장중 의도 중 시장가 비율. 장전은 지정가만이다.
#   - FAIR_VOL_PER_MIN · OVERNIGHT_VOL: 가상 적정가의 분당 · 밤사이 변동 폭(±, 균등). NOISE: 지정가가 적정가에서 벗어나는 폭(±).
#   - ORDER_VALUE: 주문 한 건의 금액 범위(원). 수량 = 금액 ÷ 가격.
#   - CALENDAR_AHEAD_DAYS · TICK_SECONDS · STATE_PATH: 데몬(Sim::Daemon)의 달력 앞 여유 · tick 간격 · 상태 파일.
#   - CALENDAR_MAX_RETRIES: 달력이 모자랄 때 두 배씩 늘려 다시 읽는 최대 횟수. 넘으면 예외(그 tick 은 로그만, 다음 tick 에 다시).
#   - SETTLE_PAD: 빨리 감기가 마지막 영업일 뒤로 달력 행을 더 채우는 날 수(결제 T+2 가 달력을 읽는다).
module Securities
  module Sim
    module Config
      SEED = Seed::DEFAULT_SEED
      ORDERS_PER_DAY = 1_000
      PRE_OPEN_SHARE = Rational(3, 10)
      MARKET_SHARE = Rational(1, 10)
      FAIR_VOL_PER_MIN = 0.001
      OVERNIGHT_VOL = 0.01
      NOISE = 0.005
      ORDER_VALUE = (500_000..5_000_000)
      CALENDAR_AHEAD_DAYS = 14 # 데몬이 가상 오늘보다 며칠 앞까지 달력 행을 채워 두는가(Clock 이 다음 영업일을 읽는다)
      TICK_SECONDS = 1 # 데몬 한 번 도는 실시간 간격
      CALENDAR_MAX_RETRIES = 12 # 14일에서 두 배씩 12번이면 앞으로 57,344일(약 157년). 이보다 오래 꺼 뒀다면 예외가 맞다
      SETTLE_PAD = 14
      STATE_PATH = Rails.root.join("storage", "sec_sim_state.json").freeze
    end
  end
end
