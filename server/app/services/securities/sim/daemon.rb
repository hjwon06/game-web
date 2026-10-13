# 끝없는 달력 위의 실시간 데몬. 시뮬레이터 규칙이다. 공장 Simulation::Runner 틀(주입 · stop! · 단계 실패 격리)을 따른다.
#   - started_at(실시간 기준점)은 상태 파일에 처음 한 번만 쓰고, 다시 켜면 그대로 읽는다. 매번 Time.current 면 재시작마다 가상 시계가 0 으로 돌아간다.
#   - tick(real_now) 한 번 = 가상 지금 = Clock.market_time(real_now) → Calendar.extend!(가상 오늘 + CALENDAR_AHEAD_DAYS)
#     → Runner.advance(지난 가상 시각, 가상 지금). 창은 반열림이라 tick 끼리 겹치지도 빠지지도 않는다.
#   - 지난 가상 시각은 성공했을 때만 앞으로 간다. 예외가 나면 로그 한 줄 남기고 다음 tick 이 같은 창부터 다시 돈다(client_key 가 멱등).
#   - 첫 tick 의 지난 가상 시각은 첫 장 00:00 이다(재시작도 따라잡기 = 재생. 중복 주문 없음).
#   - 가상 날짜가 바뀔 때 그날 접수 · 상태별 · 거절 사유별을 한 줄 남긴다. 한 창이 여러 날이면(따라잡기) 마지막 날짜에 합쳐진다.
# 증권 DB 만 쓴다(Calendar · Clock · Runner 가 전부 Securities::Record).
module Securities
  module Sim
    class Daemon
      attr_reader :started_at

      def initialize(state_path: Config::STATE_PATH, runner: Runner.new(seed: Config::SEED), logger: Rails.logger,
                     started_at: nil)
        @state_path = Pathname(state_path)
        @runner = runner
        @logger = logger
        @started_at = load_or_create_state(started_at)
        @from = nil
        @day = nil
        @totals = empty_totals
        @stopped = false
      end

      def stop!
        @stopped = true
      end

      def run
        @logger.info("sec_sim start started_at=#{@started_at.iso8601(3)}")
        until @stopped
          sleep(Config::TICK_SECONDS - (Time.current.to_f % Config::TICK_SECONDS))
          tick(Time.current) unless @stopped
        end
        @logger.info("sec_sim stop")
      end

      # 성공하면 Runner::Result, 예외가 나면 nil(지난 가상 시각은 그대로).
      def tick(real_now)
        to = virtual_now(real_now)
        Calendar.extend!(through: to.in_time_zone(Phase::ZONE).to_date + Config::CALENDAR_AHEAD_DAYS)
        from = @from || Clock.at_minute(Seed::FIRST_MARKET_DAY, 0)
        result = @runner.advance(from: from, to: to)
        @from = to
        record(result, to)
        result
      rescue StandardError => e
        @logger.error("sec_sim tick failed from=#{(@from || Seed::FIRST_MARKET_DAY).iso8601}: #{e.class} #{e.message}")
        nil
      end

      private

      # market_time 은 달력이 모자라면 Missing 이다(오래 꺼 둔 뒤 첫 tick). 직전 가상 날짜 + 앞 여유까지 채우고, 모자라면 두 배씩 늘려 다시 읽는다.
      def virtual_now(real_now)
        through = (@day || Seed::FIRST_MARKET_DAY) + Config::CALENDAR_AHEAD_DAYS
        step = Config::CALENDAR_AHEAD_DAYS
        begin
          Calendar.extend!(through: through)
          Clock.market_time(real_now, started_at: @started_at, first_day: Seed::FIRST_MARKET_DAY)
        rescue Calendar::Missing
          through += step
          step *= 2
          retry
        end
      end

      def record(result, to)
        day = to.in_time_zone(Phase::ZONE).to_date
        log_day if @day && day != @day
        @totals = empty_totals if @day != day
        @day = day
        @totals[:placed] += result.placed
        result.by_status.each { |k, v| @totals[:by_status][k] += v }
        result.by_reject_reason.each { |k, v| @totals[:by_reject_reason][k] += v }
      end

      def log_day
        @logger.info("sec_sim day=#{@day.iso8601} placed=#{@totals[:placed]} " \
                     "status=#{@totals[:by_status].to_h} reject=#{@totals[:by_reject_reason].to_h}")
      end

      def empty_totals
        { placed: 0, by_status: Hash.new(0), by_reject_reason: Hash.new(0) }
      end

      def load_or_create_state(given)
        return Time.iso8601(JSON.parse(@state_path.read).fetch("started_at")) if @state_path.exist?

        started = given || Time.current
        @state_path.dirname.mkpath
        tmp = @state_path.sub_ext(".json.tmp")
        tmp.write(JSON.generate("started_at" => started.iso8601(9)))
        tmp.rename(@state_path)
        started
      end
    end
  end
end
