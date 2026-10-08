module Simulation
  # 1초마다 스냅샷을 읽어 tick 하고, 10초 경계에서 flush → Ops::Tick → Inbound → LineFeed → Inspection → Shipping 을 돌리고
  # 60초 경계에서 Logistics 를 부른다. SIGTERM 에서는 마지막 flush 없이 끝난다.
  class Runner
    MAX_FAILURES = 3
    MAX_PENDING = 6 # 10초 구간 6개 = 1분

    def initialize(logger: Rails.logger, flusher: Flusher, logistics: Logistics, inbound: Inbound, ops_tick: Ops::Tick,
                   line_feed: LineFeed, inspection: Inspection, shipping: Shipping)
      @logger = logger
      @flusher = flusher
      @logistics = logistics
      @inbound = inbound
      @ops_tick = ops_tick
      @line_feed = line_feed
      @inspection = inspection
      @shipping = shipping
      @pending = []
      @accumulator = Accumulator.new
      @rng = Random.new(Config::SEED)
      @stopped = false
    end

    def stop!
      @stopped = true
    end

    def run
      until @stopped
        sleep(Config::TICK_SECONDS - (Time.current.to_f % Config::TICK_SECONDS))
        step unless @stopped
      end
    end

    # tick 은 방금 지난 1초를 뜻하므로 구간 소속은 0.5초 전 시각으로 정한다.
    def step(now = Time.current)
      bucket = bucket_of(now.to_f - 0.5)
      @accumulator.tick(snapshot, @rng)
      flush(bucket) if bucket_of(now.to_f + 0.5) > bucket
    end

    private

    def snapshot
      Machine.order(:id).pluck(:code, :state, :version).map do |code, state, version|
        { code: code, state: state, version: version }
      end
    end

    # 롤백된 구간은 누적기째 보류 목록에 두고 같은 bucket_start 로 다음 경계에서 재시도한다.
    # 새 틱은 새 누적기에 쌓이므로 두 구간이 합쳐지지 않는다. 중복 기록은 Flusher 의 ON CONFLICT 가 막는다.
    # 오래된 구간부터 처리하고 하나가 실패하면 멈춘다. 뒤 구간이 먼저 기록되면 작업지시 완료 순서가 뒤집힌다.
    def flush(bucket)
      current = @accumulator
      @accumulator = Accumulator.new
      @pending << { bucket: bucket, accumulator: current, failures: 0 }
      drop_overflow
      @pending.shift while @pending.any? && settled?(@pending.first)
      boundary = bucket + Config::BUCKET_SECONDS
      # 순서: 작업 진행(Tick) → 입고(Inbound) → 라인 공급 → 검사 → 출하. 방금 끝난 하차·검사·pick 의 다음 작업이 같은 경계에서 계획된다.
      isolated("ops tick", boundary) { @ops_tick.call(now: boundary) }
      isolated("inbound", boundary) { @inbound.call(now: boundary, logger: @logger) }
      isolated("line feed", boundary) { @line_feed.call(now: boundary, logger: @logger) }
      isolated("inspection", boundary) { @inspection.call(now: boundary, logger: @logger) }
      isolated("shipping", boundary) { @shipping.call(now: boundary, logger: @logger) }
      logistics(boundary) if (boundary.to_i % Config::LOGISTICS_SECONDS).zero?
      isolated("balance log", boundary) { log_balance(boundary) } if (boundary.to_i % Config::BALANCE_LOG_SECONDS).zero?
    end

    # 자재 수요(분당 필요한 feed 횟수)와 지게차 처리량(분당 작업 수)을 한 줄로 남긴다. 수요가 처리량의 절반을 넘으면 생산이 굶는다.
    def log_balance(boundary)
      balance = LineFeed.new(now: boundary, logger: @logger).balance
      @logger.info("sim balance #{boundary.utc.iso8601} est_feed_per_min=#{balance[:est_feed_per_min]} " \
                   "forklift_capacity_per_min=#{balance[:forklift_capacity_per_min]}")
    end

    # Flusher·Logistics 와 별개로 돈다. 하나가 예외를 던져도 나머지와 다음 경계는 계속된다.
    def isolated(name, boundary)
      yield
    rescue StandardError => e
      @logger.error("sim #{name} failed #{boundary.utc.iso8601}: #{e.class} #{e.message}")
    end

    # 60초 경계마다 Flusher 다음에 한 번. 실패해도 Runner·Flusher 는 멈추지 않는다.
    def logistics(boundary)
      @logistics.call(now: boundary, logger: @logger)
    rescue StandardError => e
      @logger.error("sim logistics failed #{boundary.utc.iso8601}: #{e.class} #{e.message}")
    end

    def drop_overflow
      while @pending.size > MAX_PENDING
        dropped = @pending.shift
        @logger.warn("sim flush dropped bucket #{dropped[:bucket]}: pending over #{MAX_PENDING}")
      end
    end

    # 성공하면 true, 3회 연속 실패하면 폐기(true), 그 외에는 보류 유지(false → 호출부가 멈춘다).
    def settled?(item)
      @flusher.call(item[:accumulator], item[:bucket])
      true
    rescue StandardError => e
      item[:failures] += 1
      @logger.error("sim flush failed (#{item[:failures]}/#{MAX_FAILURES}) #{item[:bucket]}: #{e.class} #{e.message}")
      return false if item[:failures] < MAX_FAILURES

      @logger.warn("sim flush dropped bucket #{item[:bucket]} after #{MAX_FAILURES} failures")
      true
    end

    def bucket_of(epoch_seconds)
      Time.zone.at((epoch_seconds / Config::BUCKET_SECONDS).floor * Config::BUCKET_SECONDS)
    end
  end
end
