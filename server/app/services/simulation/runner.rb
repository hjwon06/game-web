module Simulation
  # 1초마다 스냅샷을 읽어 tick 하고, 10초 경계에서 flush 한다. SIGTERM 에서는 마지막 flush 없이 끝난다.
  class Runner
    MAX_FAILURES = 3

    def initialize(logger: Rails.logger, flusher: Flusher)
      @logger = logger
      @flusher = flusher
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
    def flush(bucket)
      current = @accumulator
      @accumulator = Accumulator.new
      @pending << { bucket: bucket, accumulator: current, failures: 0 }
      @pending.reject! { |item| settled?(item) }
    end

    # 성공하면 true, 3회 연속 실패하면 폐기(true), 그 외에는 보류 유지(false).
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
