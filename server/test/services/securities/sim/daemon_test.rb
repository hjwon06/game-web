require "test_helper"
require "tmpdir"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# 실시간 데몬(Sim::Daemon). 실시간은 tick 인자로 주입한다. Runner 는 창만 기록하는 가짜를 쓰고,
# T4 만 진짜 Runner 로 돌려 SQL 이 전부 증권 풀로 갔는지 본다.
# 변이 검사(AC): 상태 파일 대신 매번 Time.current → T2 상태 파일, tick 예외 때 지난 시각을 앞으로 옮기기 → T2 재시도.
class Securities::Sim::DaemonTest < ActiveSupport::TestCase
  KST = ActiveSupport::TimeZone["Asia/Seoul"]
  Result = Securities::Sim::Runner::Result
  STARTED = Time.utc(2026, 10, 1, 0, 0, 0)

  # advance 인자를 기록한다. fail_first 만큼은 기록한 뒤 예외를 낸다.
  class RecordingRunner
    attr_reader :windows

    def initialize(fail_first: 0, placed: 0)
      @windows = []
      @fail_first = fail_first
      @placed = placed
    end

    def advance(from:, to:)
      @windows << [from, to]
      if @fail_first.positive?
        @fail_first -= 1
        raise "boom"
      end
      Result.new(placed: @placed, by_status: Hash.new(0).merge("filled" => @placed), by_reject_reason: Hash.new(0))
    end
  end

  setup do
    @dir = Dir.mktmpdir("sec_sim_test")
    @path = File.join(@dir, "sec_sim_state.json")
    @log = StringIO.new
    @logger = Logger.new(@log)
  end

  teardown { FileUtils.remove_entry(@dir) }

  def daemon(runner, started_at: STARTED)
    Securities::Sim::Daemon.new(state_path: @path, runner: runner, logger: @logger, started_at: started_at)
  end

  def speed
    Securities::Clock.defaults.fetch("speed")
  end

  def market_real
    Securities::Phase::SCHEDULE.then { |s| (s.last[2] - s.first[1]) * 60 / speed }
  end

  test "T2 상태 파일: 없으면 만들고 새 Daemon 은 같은 started_at 을 읽는다" do
    assert_not File.exist?(@path)
    first = daemon(RecordingRunner.new)

    assert File.exist?(@path)
    assert_equal STARTED.to_r, first.started_at.to_r
    again = daemon(RecordingRunner.new, started_at: STARTED + 3600) # 다시 켠 시각을 줘도 파일이 이긴다

    assert_equal STARTED.to_r, again.started_at.to_r
    assert_equal STARTED.to_r, Time.iso8601(JSON.parse(File.read(@path)).fetch("started_at")).to_r
  end

  test "T2 창: 실시간을 주입한 tick 의 가상 창이 이어진다(겹침 · 빈틈 없음)" do
    runner = RecordingRunner.new
    sim = daemon(runner)

    [10, 20, 45].each { |sec| sim.tick(STARTED + sec) }

    windows = runner.windows
    assert_equal 3, windows.size
    assert_equal KST.local(2026, 11, 2, 0, 0), windows.first.first, "첫 창은 첫 장 00:00 부터(따라잡기)"
    # 장 시작(Phase::SCHEDULE 처음 시작 = 08:30)에서 실시간 초 × 배속만큼 간 가상 시각이다.
    assert_equal KST.local(2026, 11, 2, 8, 30) + (10 * speed), windows.first.last
    windows.each_cons(2) { |a, b| assert_equal a.last, b.first, "창이 이어지지 않는다" }
    assert(windows.all? { |from, to| from < to })
    assert_equal KST.local(2026, 11, 2, 8, 30) + (45 * speed), windows.last.last
  end

  test "T2 재시도: 예외를 낸 tick 은 로그만 남기고 다음 tick 이 같은 창부터 다시 돈다" do
    runner = RecordingRunner.new(fail_first: 1)
    sim = daemon(runner)

    assert_nil sim.tick(STARTED + 10)
    assert_instance_of Result, sim.tick(STARTED + 20)
    assert_instance_of Result, sim.tick(STARTED + 30)

    failed, retried, next_window = runner.windows
    assert_equal failed.first, retried.first, "같은 창부터 다시 돌지 않았다"
    assert_operator retried.last, :>, failed.last
    assert_equal retried.last, next_window.first
    assert_includes @log.string, "tick failed"
  end

  test "T2 오래 꺼 둔 뒤 첫 tick: 달력을 스스로 늘려 따라잡는다" do
    runner = RecordingRunner.new
    sim = daemon(runner)

    result = sim.tick(STARTED + (5 * 86_400)) # 실시간 5일 ≒ 가상 영업일 수백 개

    assert_instance_of Result, result
    to = runner.windows.last.last
    assert_operator to.to_date, :>, Date.new(2027, 3, 1)
    assert_operator Securities::MarketDay.maximum(:trade_date), :>, to.to_date, "가상 오늘 앞까지 달력이 있다"
  end

  test "가상 날짜가 바뀌면 그날 접수 · 상태별을 한 줄 남긴다" do
    sim = daemon(RecordingRunner.new(placed: 7))

    sim.tick(STARTED + 10)                 # 11-02 장중
    sim.tick(STARTED + market_real + 10)   # 11-02 저녁(밤 구간)
    assert_not_includes @log.string, "sec_sim day="
    sim.tick(STARTED + market_real + 290)  # 11-03 새벽(자정 지남)

    assert_includes @log.string, "sec_sim day=2026-11-02 placed=14"
    assert_match(/status=\{"filled"\s*=>\s*14\}/, @log.string)
  end

  test "T4 primary 를 안 쓴다: tick 동안 나간 SQL 의 연결이 전부 Securities::Record 풀이다" do
    Securities::Seed.run!(seed: Securities::Sim::Config::SEED)
    sim = daemon(Securities::Sim::Runner.new(seed: Securities::Sim::Config::SEED))
    pools = []
    callback = ->(*, payload) { pools << payload[:connection]&.pool }

    result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { sim.tick(STARTED + 60) }

    assert_instance_of Result, result
    assert_operator result.placed, :>=, 1
    assert_operator pools.size, :>=, 10, "쿼리를 못 잡았으면 이 단언은 아무것도 못 본다"
    assert_equal [Securities::Record.connection_pool], pools.uniq
    assert_not_includes pools, ActiveRecord::Base.connection_pool
  end
end
