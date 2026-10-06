module Simulation
  # 메모리 누적기. DB 를 읽지도 쓰지도 않는다. 구간(10초) 동안 기계별 생산량을 더한다.
  class Accumulator
    Entry = Struct.new(:version, :good_qty, :defect_qty, :discarded, keyword_init: true)

    attr_reader :entries

    def initialize
      @entries = {}
    end

    # snapshot: [{ code:, state:, version: }, ...] — 1초분.
    def tick(snapshot, rng)
      snapshot.each do |machine|
        entry = @entries[machine[:code]] ||= Entry.new(version: machine[:version], good_qty: 0,
                                                       defect_qty: 0, discarded: false)
        entry.discarded = true if machine[:version] != entry.version
        next if entry.discarded || machine[:state] != "running"

        add_production(entry, machine[:code], rng)
      end
    end

    def entry(code)
      @entries[code]
    end

    def reset!
      @entries = {}
    end

    private

    def add_production(entry, code, rng)
      produced = poisson(Config.rate(code), rng)
      defects = binomial(produced, Config.defect_rate(code), rng)
      entry.good_qty += produced - defects
      entry.defect_qty += defects
    end

    # Knuth 방식. rate 가 1 이하라 반복 횟수는 평균 2회 안팎이다.
    def poisson(rate, rng)
      limit = Math.exp(-rate)
      count = 0
      product = rng.rand
      while product > limit
        count += 1
        product *= rng.rand
      end
      count
    end

    def binomial(trials, probability, rng)
      Array.new(trials) { rng.rand < probability }.count(true)
    end
  end
end
