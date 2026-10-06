module Simulation
  # 1초마다 스냅샷을 읽어 tick 하고, 10초 경계에서 flush 한다. SIGTERM 에서는 마지막 flush 없이 끝난다.
  class Runner
    def initialize(logger: Rails.logger)
      @logger = logger
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

    def flush(bucket)
      Flusher.call(@accumulator, bucket)
    rescue StandardError => e
      @logger.error("sim flush failed: #{e.class} #{e.message}")
      @accumulator.reset! # 유실 감수. 쌓아 두면 다음 구간에 두 구간이 합쳐진다.
    end

    def bucket_of(epoch_seconds)
      Time.zone.at((epoch_seconds / Config::BUCKET_SECONDS).floor * Config::BUCKET_SECONDS)
    end
  end
end
