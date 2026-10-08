module Simulation
  # 시뮬레이션 숫자는 이 파일에만 둔다.
  module Config
    SEED = 20_261_006
    TICK_SECONDS = 1
    BUCKET_SECONDS = 10

    DEFAULT_RATE = 0.5
    DEFAULT_DEFECT_RATE = 0.03

    # 생산 속도 배율. 지게차 2대가 감당하는 물량으로 줄인다(forklift_load 참고). 기계별 상대 차이는 RATES 가 그대로 가진다.
    RATE_SCALE = 0.33

    # 기계 code 별 초당 생산 기대값(배율 적용 전). 읽을 때는 Config.rate 를 쓴다.
    RATES = {
      "M1" => 0.8, "M2" => 0.5, "M3" => 0.6, "M4" => 0.7, "M5" => 0.9, "M6" => 0.4,
      "M7" => 0.65, "M8" => 0.55, "M9" => 0.75, "M10" => 0.45, "M11" => 0.85, "M12" => 0.6
    }.freeze

    # 기계 code 별 불량률.
    DEFECT_RATES = {
      "M1" => 0.02, "M2" => 0.04, "M3" => 0.05, "M4" => 0.03, "M5" => 0.01, "M6" => 0.05,
      "M7" => 0.02, "M8" => 0.03, "M9" => 0.04, "M10" => 0.01, "M11" => 0.03, "M12" => 0.05
    }.freeze

    # 물량 단위. 자재 소비가 분당 500~700개라 팔레트 100개로는 feed 가 지게차 처리량을 넘는다 — 팔레트 500개 기준으로 맞춘다.
    PALLET_QTY = 500                         # 팔레트 1개 = 500 ea. 원자재 하차·적치·라인 공급(feed)의 단위
    BIN_CAPACITY = PALLET_QTY * 4            # raw·fg 칸 1개 = 팔레트 4개
    LINE_SIDE_CAPACITY = PALLET_QTY * 8      # 라인 공급대 하나(품목 무관 합) = 팔레트 8개. 800 이면 팔레트 1개 feed 뒤 여유가 없다
    PICK_QTY = PALLET_QTY                    # 완제품 피킹 단위
    FORKLIFT_COUNT = 2                       # Resource::DEFAULTS 의 지게차 수. 화면 원칙(운반 주체 ≤5)상 늘리지 않는다
    MATERIAL_PER_FG = 1.7                    # 완제품 1개당 원자재 소비(ea). dev 실측: 원자재 750 ea/분 ÷ 완제품 450 ea/분
    FORKLIFT_TASK_SECONDS = 40              # 지게차 작업(putaway 45·pick 40·feed 35) 평균 소요. 처리량 추정용
    FORKLIFT_ADMIT_SECONDS = 60              # 지게차 대기열(가장 빨리 비는 지게차까지 남은 초)이 이보다 길면 pick·putaway 를 새로 계획하지 않는다. feed 는 제한 없음

    # 수요/공급 로그: Runner 가 이 간격마다 est_feed_per_min 과 forklift_capacity_per_min 을 한 줄로 남긴다.
    BALANCE_LOG_SECONDS = 600

    # 물류(자재 소비) 숫자.
    LOGISTICS_SECONDS = 60
    BACKFLUSH_CHUNK_MAX = 300                # 작업지시 1건이 한 분에 소비하는 완제품 수 상한. 밀린 분량은 이 크기로 나눠 처리한다
    BACKLOG_CAP = BACKFLUSH_CHUNK_MAX * 2    # 작업지시별 미소비량(pending) 상한(2분어치). 넘는 분량은 소급하지 않고 버린다
    MATERIAL_SHORT_CHECK_SECONDS = 60        # 자재 대기 판단 구간: 라인사이드가 이만큼의 생산분을 못 대면 그 기계는 선다
    STARVE_LOG_MINUTES = 10                  # 작업지시가 이만큼 연속으로 자재 부족이면 그 뒤 이 간격마다 로그 1줄

    # 입고(트럭 → 하차 → 칸 적치) 숫자. Runner 가 BUCKET_SECONDS(10초)마다 Inbound 를 부른다.
    FORECAST_SECONDS = 1800                  # 트럭 적재량 = 이만큼(30분)의 자재 수요를 팔레트로 올림한 값
    TRUCK_INTERVAL_SECONDS = (180..360).freeze # 트럭 도착 간격(초) 균등난수 3~6분
    PALLETS_PER_TRUCK = (4..12).freeze       # 적재량 하한·상한(팔레트). 칸이 모자라면 하한 아래로도 줄인다
    PUTAWAY_LOOKBACK_SECONDS = 21_600        # 하차가 끝난 뒤 이만큼까지만 적치 대기분을 다시 찾는다(tasks 스캔 상한)
    MAX_PUTAWAY_CANCELS = 3                  # 한 팔레트의 적치가 이만큼 취소되면 더 계획하지 않는다
    MAX_LOAD_CANCELS = 3                     # 한 수주 라인·로트의 상차(load)가 이만큼 취소되면 더 계획하지 않는다

    # 라인 공급(feed): line_side 자재 재고가 이만큼의 예상 소비량에 못 미치면 팔레트 1개(PALLET_QTY)를 공급한다.
    LINE_FEED_FORECAST_SECONDS = 600

    # 검사: 로트별로 qc 에 쌓인 미검사 수량이 팔레트(PALLET_QTY) 이상이거나 가장 오래된 도착분이 이만큼 지나면 inspect 작업 1건.
    # 1건 수량은 min(미검사량, PALLET_QTY)이고 합격분 적치도 그 단위라, 완제품 적치가 팔레트 단위로 일어난다.
    # 작업지시(로트)당 양품이 분당 8~18개라 5분이면 40~90개씩 잘게 나갔다(dev 실측: 완제품 적치 37건 평균 52개). 20분이면 150~350개로 팔레트에 가까워진다.
    INSPECT_MAX_WAIT_SECONDS = 1200
    INSPECT_LOOKBACK_SECONDS = 21_600 # 검사 끝난 뒤 이만큼까지만 합격분 적치 대기를 다시 찾는다(tasks 스캔 상한)

    # 출하: pick 은 PICK_QTY 단위, 한 번에 라인당 최대 PICKS_PER_LINE 건. 한 번 훑는 수주 라인 수 상한은 SHIP_LINES_LIMIT.
    PICKS_PER_LINE = 5
    SHIP_LINES_LIMIT = 50

    # 수주 한 줄의 수량 = 최근 NEW_ORDER_LOOKBACK_SECONDS 의 완제품 양품 생산량 x (NEW_ORDER_INTERVAL_SECONDS / 룩백) x NEW_ORDER_RATIO 를 PICK_QTY 단위로 내림.
    NEW_ORDER_INTERVAL_SECONDS = 600
    NEW_ORDER_LOOKBACK_SECONDS = 1800
    NEW_ORDER_RATIO = 0.9                    # 출하 수요를 생산의 90% 로 맞춰 완제품이 서서히 쌓이게 한다
    CUSTOMERS = %w[한빛정공 대성기계 서진산업 미래오토].freeze # 시드 수주의 고객명. 순환해서 쓴다

    # 이 시각 이전 생산은 재고로 소급하지 않는다. ENV > 최신 sim_epochs(rake sim:rebase) > locations 첫 생성 시각. 모두 없으면 nil.
    def self.inventory_epoch
      raw = ENV["INVENTORY_EPOCH"].presence
      return SimEpoch.latest&.started_at || Location.minimum(:created_at) unless raw

      Time.zone.parse(raw) or raise ArgumentError, "INVENTORY_EPOCH 를 시각으로 읽을 수 없다: #{raw}"
    end

    def self.rate(code)
      RATES.fetch(code, DEFAULT_RATE) * RATE_SCALE
    end

    # 지게차 예상 가동률(0~1)을 Config 값만으로 계산한다. 12대가 모두 돌 때의 상한이다.
    #   양품 ea/분   = Σ rate(code) x (1 - defect_rate(code)) x 60
    #   원자재 ea/분 = 양품 ea/분 x MATERIAL_PER_FG
    #   건수/분      = 원자재 적치(원자재 / PALLET_QTY) + feed(원자재 / PALLET_QTY)
    #                  + 완제품 적치(양품 / PALLET_QTY) + pick(양품 / PICK_QTY)
    #   가동률       = 건수/분 x FORKLIFT_TASK_SECONDS / (FORKLIFT_COUNT x 60)
    # 기본값: 양품 ≈ 149 ea/분, 원자재 ≈ 253 ea/분 → 0.51 + 0.51 + 0.30 + 0.30 = 1.62 건/분 → 1.62 x 40 / 120 ≈ 0.54.
    # 팔레트를 못 채우고 대기 시간(INSPECT_MAX_WAIT_SECONDS = 20분, 부분 팔레트 약 150~350개) 때문에 나가는 부분 팔레트가 있어 실제는 조금 높다 — 테스트는 0.70 을 넘지 않게 지킨다.
    # 진입 제한: 지게차 대기열이 FORKLIFT_ADMIT_SECONDS 를 넘으면 pick·putaway 계획을 미루고 feed 만 계획한다.
    # 그래서 실제 가동률은 이 추정값을 넘어 계속 오르지 않고 대기열 상한에서 눌리며, 라인 공급(feed)이 항상 먼저 지게차를 받는다. 수식은 진입 제한과 무관하다.
    def self.forklift_load
      good_per_minute = RATES.keys.sum { |code| rate(code) * (1 - defect_rate(code)) } * 60
      material_per_minute = good_per_minute * MATERIAL_PER_FG
      tasks_per_minute = (material_per_minute / PALLET_QTY) * 2 + good_per_minute / PALLET_QTY + good_per_minute / PICK_QTY
      tasks_per_minute * FORKLIFT_TASK_SECONDS / (FORKLIFT_COUNT * 60.0)
    end

    def self.defect_rate(code)
      DEFECT_RATES.fetch(code, DEFAULT_DEFECT_RATE)
    end
  end
end
