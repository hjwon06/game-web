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

    def self.rate(code)
      RATES.fetch(code, DEFAULT_RATE)
    end

    def self.defect_rate(code)
      DEFECT_RATES.fetch(code, DEFAULT_DEFECT_RATE)
    end
  end
end
