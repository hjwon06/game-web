# 끝없는 달력 위의 실시간 데몬. 시뮬레이터 규칙이다. 공장 Simulation::Runner 틀(주입 · stop! · 단계 실패 격리)을 따른다.
#   - started_at(실시간 기준점)은 상태 파일에 처음 한 번만 쓰고, 다시 켜면 그대로 읽는다. 매번 Time.current 면 재시작마다 가상 시계가 0 으로 돌아간다.
#   - cursor(마지막으로 끝낸 가상 시각)도 같은 상태 파일에 tick 이 성공할 때마다 tmp → rename 으로 쓴다. 다시 켜면 거기서 잇는다.
#     없으면 첫 장 00:00 이다. 실시간 하루 = 가상 영업일 수십 일이라 cursor 가 없으면 재시작마다 처음부터 재생한다.
#   - tick(real_now) 한 번 = 가상 지금 = Clock.market_time(real_now) → Calendar.extend!(가상 오늘 + CALENDAR_AHEAD_DAYS)
#     → Runner.advance(cursor, 가상 지금). 창은 반열림이라 tick 끼리 겹치지도 빠지지도 않는다.
#   - 창은 앞으로만 간다: 가상 지금 ≤ cursor 면(시계 보정으로 실시간이 뒤로 갔다) advance 를 부르지 않고 cursor 도 두지 않는다.
#   - cursor 는 성공했을 때만 앞으로 간다. 예외가 나면 로그 한 줄 남기고 다음 tick 이 같은 창부터 다시 돈다(client_key 가 멱등).
#   - 가상 날짜가 바뀔 때, 그리고 run 이 멈출 때 그날 접수 · 상태별 · 거절 사유별을 한 줄 남긴다.
#     한 창이 여러 날이면(따라잡기) 마지막 날짜에 합쳐진다. 재시작하면 그날 합계는 0 에서 다시 센다(로그만 영향, 주문은 그대로).
#   - 달력 늘리기 재시도는 Config::CALENDAR_MAX_RETRIES 번까지다. 넘으면 예외 → tick 이 로그를 남기고 다음 tick 에 다시.
# 증권 DB 만 쓴다(Calendar · Clock · Runner 가 전부 Securities::Record).
module Securities
  module Sim
    class Daemon
      attr_reader :started_at

      def initialize(state_path: Config::STATE_PATH, runner: Runner.new(seed: Config::SEED), logger: Rails.logger,
                     started_at: nil, max_retries: Config::CALENDAR_MAX_RETRIES, clock: Clock)
        @state_path = Pathname(state_path)
        @runner = runner
        @logger = logger
        @clock = clock
        @max_retries = max_retries
        @from = nil # cursor
        @started_at = load_or_create_state(started_at)
        @day = nil
        @totals = empty_totals
        @stopped = false
      end

      def stop!
        @stopped = true
      end

      def run
        @logger.info("sec_sim start started_at=#{@started_at.iso8601(3)} cursor=#{@from&.iso8601(3) || 'none'}")
        until @stopped
          sleep(Config::TICK_SECONDS - (Time.current.to_f % Config::TICK_SECONDS))
          tick(Time.current) unless @stopped
        end
        log_day if @day
        @logger.info("sec_sim stop")
      end

      # 성공하면 Runner::Result, 건너뛰었거나 예외가 나면 nil(cursor 는 그대로).
      def tick(real_now)
        to = virtual_now(real_now)
        if @from && to <= @from
          @logger.warn("sec_sim tick skipped: to=#{to.iso8601(3)} <= cursor=#{@from.iso8601(3)}") if to < @from
          return nil
        end

        Calendar.extend!(through: to.in_time_zone(Phase::ZONE).to_date + Config::CALENDAR_AHEAD_DAYS)
        result = @runner.advance(from: @from || Clock.at_minute(Seed::FIRST_MARKET_DAY, 0), to: to)
        @from = to
        record(result, to)
        write_state
        result
      rescue StandardError => e
        @logger.error("sec_sim tick failed from=#{(@from || Seed::FIRST_MARKET_DAY).iso8601}: #{e.class} #{e.message}")
        nil
      end

      private

      # market_time 은 달력이 모자라면 Missing 이다(오래 꺼 둔 뒤 첫 tick). 직전 가상 날짜 + 앞 여유까지 채우고,
      # 모자라면 두 배씩 늘려 다시 읽는다. 최대 @max_retries 번, 넘으면 마지막 Missing 을 그대로 올린다.
      def virtual_now(real_now)
        through = (@day || Seed::FIRST_MARKET_DAY) + Config::CALENDAR_AHEAD_DAYS
        step = Config::CALENDAR_AHEAD_DAYS
        retries = 0
        begin
          Calendar.extend!(through: through)
          @clock.market_time(real_now, started_at: @started_at, first_day: Seed::FIRST_MARKET_DAY)
        rescue Calendar::Missing
          raise if retries >= @max_retries

          retries += 1
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

      # 파일이 있으면 started_at · cursor 를 읽는다(cursor 는 정확한 유리수 cursor_r 이 이긴다). 없으면 만든다.
      def load_or_create_state(given)
        if @state_path.exist?
          state = JSON.parse(@state_path.read)
          @from = parse_cursor(state)
          return Time.iso8601(state.fetch("started_at"))
        end

        started = given || Time.current
        write_state(started)
        started
      end

      def parse_cursor(state)
        return Time.at(Rational(state["cursor_r"])).in_time_zone(Phase::ZONE) if state["cursor_r"]

        state["cursor"] && Time.iso8601(state["cursor"]).in_time_zone(Phase::ZONE)
      end

      # 같은 디렉터리의 tmp 에 쓰고 rename 한다. 쓰는 도중 죽어도 상태 파일은 앞 내용 그대로다.
      def write_state(started = @started_at)
        state = { "started_at" => started.iso8601(9) }
        state.merge!("cursor" => @from.iso8601(9), "cursor_r" => @from.to_r.to_s) if @from
        @state_path.dirname.mkpath
        tmp = @state_path.sub_ext(".json.tmp")
        tmp.write(JSON.generate(state))
        tmp.rename(@state_path)
      end
    end
  end
end
