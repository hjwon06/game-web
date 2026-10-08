module Simulation
  # 시뮬레이션 숫자는 이 파일에만 둔다.
  module Config
    SEED = 20_261_006
    TICK_SECONDS = 1
    BUCKET_SECONDS = 10

    DEFAULT_RATE = 0.5
    DEFAULT_DEFECT_RATE = 0.03

    # 기계 code 별 초당 생산 기대값.
    RATES = {
      "M1" => 0.8, "M2" => 0.5, "M3" => 0.6, "M4" => 0.7, "M5" => 0.9, "M6" => 0.4,
      "M7" => 0.65, "M8" => 0.55, "M9" => 0.75, "M10" => 0.45, "M11" => 0.85, "M12" => 0.6
    }.freeze

    # 기계 code 별 불량률.
    DEFECT_RATES = {
      "M1" => 0.02, "M2" => 0.04, "M3" => 0.05, "M4" => 0.03, "M5" => 0.01, "M6" => 0.05,
      "M7" => 0.02, "M8" => 0.03, "M9" => 0.04, "M10" => 0.01, "M11" => 0.03, "M12" => 0.05
    }.freeze

    # 물류(자재 소비·입고 보충) 숫자.
    LOGISTICS_SECONDS = 60
    FORECAST_SECONDS = 600       # 이만큼의 예상 소비량보다 자재창고 재고가 적으면 트럭을 부른다
    REPLENISH_SECONDS = 1800     # 트럭 1대의 보충량 = 이만큼의 예상 소비량
    TRUCK_INTERVAL_SECONDS = 300 # 같은 자재 트럭 간격

    # 이 시각 이전 생산은 재고로 소급하지 않는다. ENV 우선, 없으면 locations 첫 생성 시각. 둘 다 없으면 nil.
    def self.inventory_epoch
      raw = ENV["INVENTORY_EPOCH"].presence
      return Location.minimum(:created_at) unless raw

      Time.zone.parse(raw) or raise ArgumentError, "INVENTORY_EPOCH 를 시각으로 읽을 수 없다: #{raw}"
    end

    def self.rate(code)
      RATES.fetch(code, DEFAULT_RATE)
    end

    def self.defect_rate(code)
      DEFECT_RATES.fetch(code, DEFAULT_DEFECT_RATE)
    end
  end
end
