# 종목별 가상 적정가. 시뮬레이터 규칙이다. 시장 상태(DB · 체결 · 기준가)를 읽지 않는다 — Seed.plan 과 seed 만 본다.
#   - 첫 장 시작 = 시드 기준가. 장은 09:00~15:30 390분이고 분마다 곱셈 무작위 걸음(± FAIR_VOL_PER_MIN).
#   - 다음 영업일 시작 = 전날 끝 × (1 ± OVERNIGHT_VOL). 휴장일은 건너뛴다.
#   - 날 · 종목마다 SHA-256(seed, 날짜, 종목)에서 갈라진 Random 을 쓰고, 값은 첫 장부터 그 날까지 차례로 계산한다.
#     그래서 호출 순서 · 횟수와 무관하다(메모는 같은 값을 다시 계산하지 않을 뿐이다). 프로세스가 달라도 같다.
module Securities
  module Sim
    class FairValue
      MARKET_MINUTES = Phase::SCHEDULE.last[2] - Phase::SCHEDULE.first[2] # 09:00 → 15:30 = 390

      def initialize(seed:, plan: nil)
        @seed = seed
        plan ||= Seed.plan(seed: seed)
        @bases = plan[:assets].select { |a| a[:kind] == "equity" }.to_h { |a| [a[:code], a[:base_price]] }
        @paths = {}
      end

      # minute: 그 날 09:00 부터 몇 분째인가. 장전(0 미만)은 그날 시작값, 장 끝(390 초과)은 끝값이다.
      def at(asset_code:, date:, minute:)
        path(asset_code, date)[minute.clamp(0, MARKET_MINUTES)]
      end

      private

      # 길이 MARKET_MINUTES + 1. [0] = 그날 시작, [390] = 그날 끝.
      # 영업일은 Seed.business_day? 규칙이라 달력 상한이 없다. 첫 장부터 그 날까지 앞에서 차례로 쌓는다(재귀 깊이 없음).
      def path(code, date)
        return @paths[[code, date]] if @paths.key?([code, date])

        raise ArgumentError, "#{date} 는 영업일이 아니다" unless date >= Seed::FIRST_MARKET_DAY && Seed.business_day?(date)
        raise ArgumentError, "#{code} 는 종목이 아니다" unless @bases.key?(code)

        chain_to(date).reduce(nil) do |previous, day|
          @paths[[code, day]] ||= walk(code, day, previous ? overnight(code, day, previous.last) : @bases.fetch(code).to_f)
        end
      end

      # 첫 장부터 date 까지의 영업일(오름차순).
      def chain_to(date)
        (Seed::FIRST_MARKET_DAY..date).select { |day| Seed.business_day?(day) }
      end

      def overnight(code, date, previous_end)
        [previous_end * (1 + swing(rng(code, date, "night"), Config::OVERNIGHT_VOL)), 1.0].max
      end

      def walk(code, date, start)
        random = rng(code, date, "day")
        value = start
        [start] + Array.new(MARKET_MINUTES) { value = [value * (1 + swing(random, Config::FAIR_VOL_PER_MIN)), 1.0].max }
      end

      def swing(random, vol)
        (random.rand * 2 * vol) - vol
      end

      def rng(code, date, part)
        Random.new(Digest::SHA256.hexdigest([@seed, date.iso8601, code, part].join("|")).to_i(16))
      end
    end
  end
end
