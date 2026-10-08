require "test_helper"
require "stringio"

class RunnerTest < ActiveSupport::TestCase
  T0 = Time.utc(2026, 10, 6, 12, 0, 0)

  # 지정한 구간(bucket_start)에 대해 앞 fail_times 번만 DB 오류를 던지고 그 뒤에는 실제 Flusher 를 부른다.
  class FlakyFlusher
    attr_reader :calls

    def initialize(fail_bucket:, fail_times:)
      @fail_bucket = fail_bucket
      @left = fail_times
      @calls = []
    end

    def call(accumulator, bucket_start)
      @calls << bucket_start
      if bucket_start == @fail_bucket && @left.positive?
        @left -= 1
        raise ActiveRecord::StatementInvalid, "simulated flush failure"
      end
      Simulation::Flusher.call(accumulator, bucket_start)
    end
  end

  setup do
    @machine = Machine.create!(code: "M1", name: "절단기", state: "running")
    @order = WorkOrder.create!(code: "WO-1", machine: @machine, product: "브래킷", target_qty: 100_000,
                               status: "active", started_at: Time.current)
    @log = StringIO.new
  end

  def build_runner(flusher)
    Simulation::Runner.new(logger: Logger.new(@log), flusher: flusher)
  end

  # window 번째 10초 구간의 1초 틱 10번. 마지막 틱이 경계를 넘으므로 그 틱에서 flush 가 일어난다.
  def run_window(runner, window)
    10.times { |i| runner.step(T0 + (window * 10) + 0.5 + i) }
  end

  def bucket(window)
    T0 + (window * 10)
  end

  test "flush 가 실패해도 누적을 유지하고 다음 경계에서 같은 구간이 1행으로 기록된다" do
    flusher = FlakyFlusher.new(fail_bucket: bucket(0), fail_times: 1)
    runner = build_runner(flusher)

    run_window(runner, 0)
    assert_equal 0, ProductionEvent.count, "첫 flush 는 실패했다"
    assert_equal 0, @order.reload.produced_qty

    run_window(runner, 1)

    events = ProductionEvent.where(machine: @machine).order(:bucket_start)
    assert_equal [bucket(0), bucket(1)], events.map(&:bucket_start), "실패한 구간이 같은 bucket_start 로 들어간다"
    assert_operator events.first.good_qty, :>, 0, "실패한 구간의 생산량이 살아 있다"
    assert_equal events.sum(&:good_qty), @order.reload.produced_qty, "produced_qty 는 한 번씩만 오른다"
    assert_equal [bucket(0), bucket(0), bucket(1)], flusher.calls
  end

  test "두 번 실패해도 세 번째 시도에서 기록되고 중복 행은 없다" do
    runner = build_runner(FlakyFlusher.new(fail_bucket: bucket(0), fail_times: 2))

    3.times { |window| run_window(runner, window) }

    assert_equal [bucket(0), bucket(1), bucket(2)], ProductionEvent.order(:bucket_start).map(&:bucket_start)
    assert_equal ProductionEvent.sum(:good_qty), @order.reload.produced_qty
    assert_no_match(/dropped/, @log.string)
  end

  test "3회 연속 실패한 구간만 폐기하고 경고를 남긴다" do
    runner = build_runner(FlakyFlusher.new(fail_bucket: bucket(0), fail_times: 99))

    3.times { |window| run_window(runner, window) }

    assert_equal [bucket(1), bucket(2)], ProductionEvent.order(:bucket_start).map(&:bucket_start)
    assert_equal ProductionEvent.sum(:good_qty), @order.reload.produced_qty
    assert_match(/dropped bucket .* after 3 failures/, @log.string)
    assert_equal 3, @log.string.scan("simulated flush failure").size

    run_window(runner, 3)
    assert_equal 3, @log.string.scan("simulated flush failure").size, "폐기된 구간은 더 이상 재시도하지 않는다"
  end

  # 구간 0 이 두 번 실패하는 동안 구간 1 은 시도조차 되지 않아야 한다.
  test "구간 0 이 실패한 경계에서 구간 1 은 기록되지 않고 시도도 되지 않는다" do
    flusher = FlakyFlusher.new(fail_bucket: bucket(0), fail_times: 2)
    runner = build_runner(flusher)

    run_window(runner, 0)
    run_window(runner, 1)

    assert_equal 0, ProductionEvent.count, "구간 1 이 구간 0 보다 먼저 기록되면 안 된다"
    assert_equal [bucket(0), bucket(0)], flusher.calls, "뒤 구간은 시도하지 않는다"
    assert_equal 2, @log.string.scan("simulated flush failure").size, "뒤 구간은 실패 횟수가 늘지 않는다"
  end

  test "다음 경계에서 구간 0, 1 순서로 기록된다" do
    runner = build_runner(FlakyFlusher.new(fail_bucket: bucket(0), fail_times: 2))

    3.times { |window| run_window(runner, window) }

    events = ProductionEvent.order(:id)
    assert_equal [bucket(0), bucket(1), bucket(2)], events.map(&:bucket_start), "id 순서가 구간 순서와 같다"
    assert_no_match(/dropped/, @log.string)
  end

  test "구간 0 의 생산량은 원래 지시에 들어가고 그 뒤에야 다음 지시가 활성화된다" do
    @order.update!(target_qty: 1)
    next_order = WorkOrder.create!(code: "WO-2", machine: @machine, product: "브래킷", target_qty: 100_000,
                                   status: "queued")
    runner = build_runner(FlakyFlusher.new(fail_bucket: bucket(0), fail_times: 1))

    run_window(runner, 0)
    run_window(runner, 1) # 구간 0 재시도 성공 → 지시 완료 → 지시 2 활성화 → 구간 1

    events = ProductionEvent.order(:id).to_a
    assert_equal [bucket(0), bucket(1)], events.map(&:bucket_start)
    assert_operator events.first.good_qty, :>=, 1, "구간 0 이 목표를 채운다"
    assert_equal [@order.id, next_order.id], events.map(&:work_order_id), "구간 0 은 원래 지시, 구간 1 은 다음 지시"
    assert_equal "done", @order.reload.status
    assert_equal events.first.good_qty, @order.produced_qty, "다음 지시의 생산량이 섞이지 않는다"
    assert_equal events.last.good_qty, next_order.reload.produced_qty
  end

  class AlwaysFailFlusher
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(_accumulator, bucket_start)
      @calls << bucket_start
      raise ActiveRecord::StatementInvalid, "down"
    end
  end

  test "보류가 6개를 넘으면 가장 오래된 구간부터 폐기하고 경고를 남긴다" do
    flusher = AlwaysFailFlusher.new
    runner = build_runner(flusher)
    runner.instance_variable_set(
      :@pending, (-6..-1).map { |w| { bucket: bucket(w), accumulator: Simulation::Accumulator.new, failures: 0 } }
    )

    run_window(runner, 0) # 7번째 구간이 들어와 상한을 넘는다

    pending = runner.instance_variable_get(:@pending)
    assert_equal 6, pending.size
    assert_equal [bucket(-5), bucket(-4), bucket(-3), bucket(-2), bucket(-1), bucket(0)], pending.map { |i| i[:bucket] }
    assert_match(/dropped bucket #{Regexp.escape(bucket(-6).to_s)}: pending over 6/, @log.string)
    assert_equal [bucket(-5)], flusher.calls, "맨 앞만 시도하고 멈춘다"
  end

  class RecordingLogistics
    attr_reader :calls, :events_seen

    def initialize(error: nil)
      @error = error
      @calls = []
      @events_seen = []
    end

    def call(now:, logger:)
      @calls << now
      @events_seen << ProductionEvent.count
      raise @error if @error
    end
  end

  test "Logistics 는 60초 경계에서만, Flusher 다음에 부른다" do
    logistics = RecordingLogistics.new
    runner = Simulation::Runner.new(logger: Logger.new(@log), logistics: logistics)

    5.times { |window| run_window(runner, window) }
    assert_empty logistics.calls, "50초까지는 부르지 않는다"

    run_window(runner, 5)
    assert_equal [T0 + 60], logistics.calls
    assert_equal [6], logistics.events_seen, "Logistics 가 불릴 때 그 경계의 구간은 이미 기록돼 있다"

    6.times { |i| run_window(runner, 6 + i) }
    assert_equal [T0 + 60, T0 + 120], logistics.calls
  end

  test "Logistics 가 예외를 던져도 Runner 와 다음 Flusher 는 정상이다" do
    logistics = RecordingLogistics.new(error: RuntimeError.new("boom"))
    runner = Simulation::Runner.new(logger: Logger.new(@log), logistics: logistics)

    18.times { |window| run_window(runner, window) }

    assert_equal [T0 + 60, T0 + 120, T0 + 180], logistics.calls
    assert_equal 18, ProductionEvent.count, "예외 뒤 구간도 계속 기록된다"
    assert_equal ProductionEvent.sum(:good_qty), @order.reload.produced_qty
    assert_equal 3, @log.string.scan(/sim logistics failed .*RuntimeError boom/).size
  end

  test "Logistics 실제 구현도 같은 경계에서 돌고 Flusher 를 막지 않는다" do
    runner = build_runner(Simulation::Flusher)
    7.times { |window| run_window(runner, window) }
    assert_equal 7, ProductionEvent.count
    assert_no_match(/failed/, @log.string, "Ops::Tick·Inbound 실제 구현도 같이 돌았지만 실패 로그가 없다")
    assert_equal 1, @log.string.scan(/sim logistics 2026-10-06T12:01:00Z/).size
  end

  # Ops::Tick(now:) 과 Inbound(now:, logger:) 모두 받는 기록용 대역. 공용 순서 배열에 [이름, 시각, 그때 기록된 구간 수] 를 쌓는다.
  class RecordingStep
    def initialize(name, order, error: nil)
      @name = name
      @order = order
      @error = error
    end

    def call(now:, **)
      @order << [@name, now, ProductionEvent.count]
      raise @error if @error
    end
  end

  test "Ops::Tick 과 Inbound 는 10초 경계마다 Flusher 다음에 Tick → Inbound 순서로 부른다" do
    order = []
    runner = Simulation::Runner.new(logger: Logger.new(@log), ops_tick: RecordingStep.new(:tick, order),
                                    inbound: RecordingStep.new(:inbound, order), logistics: RecordingLogistics.new)

    3.times { |window| run_window(runner, window) }

    assert_equal [[:tick, T0 + 10, 1], [:inbound, T0 + 10, 1], [:tick, T0 + 20, 2], [:inbound, T0 + 20, 2],
                  [:tick, T0 + 30, 3], [:inbound, T0 + 30, 3]], order
  end

  def build_full_runner(order, errors: {})
    steps = %i[tick inbound line_feed inspection shipping cycle_count].to_h { |name| [name, RecordingStep.new(name, order, error: errors[name])] }
    Simulation::Runner.new(logger: Logger.new(@log), logistics: RecordingLogistics.new, ops_tick: steps[:tick], inbound: steps[:inbound],
                           line_feed: steps[:line_feed], inspection: steps[:inspection], shipping: steps[:shipping],
                           cycle_count: steps[:cycle_count])
  end

  test "10초 경계마다 Tick → Inbound → 라인 공급 → 검사 → 출하 → 순환 실사 순서로 부른다" do
    order = []
    runner = build_full_runner(order)

    2.times { |window| run_window(runner, window) }

    assert_equal %i[tick inbound line_feed inspection shipping cycle_count] * 2, order.map(&:first)
    assert_equal [T0 + 10] * 6 + [T0 + 20] * 6, order.map { |_, at, _| at }
  end

  test "라인 공급·검사·출하 중 하나가 예외를 던져도 나머지와 Flusher 는 계속된다" do
    order = []
    runner = build_full_runner(order, errors: { line_feed: RuntimeError.new("feed boom"), shipping: RuntimeError.new("ship boom") })

    2.times { |window| run_window(runner, window) }

    assert_equal 2, order.count { |name, _, _| name == :inspection }
    assert_equal 2, order.count { |name, _, _| name == :shipping }, "앞 단계가 터져도 뒤 단계는 돈다"
    assert_equal 2, ProductionEvent.count
    assert_equal 2, @log.string.scan(/sim line feed failed .*RuntimeError feed boom/).size
    assert_equal 2, @log.string.scan(/sim shipping failed .*RuntimeError ship boom/).size
  end

  test "D4: 수요/공급 비(est_feed_per_min, forklift_capacity_per_min)를 600초 경계마다 한 줄 남긴다" do
    Resource.ensure_defaults!
    runner = build_full_runner([])

    59.times { |window| run_window(runner, window) }
    assert_equal 0, @log.string.scan("sim balance").size, "590초 경계까지는 남기지 않는다"

    run_window(runner, 59)
    assert_equal 1, @log.string.scan(/sim balance 2026-10-06T12:10:00Z est_feed_per_min=\S+ forklift_capacity_per_min=3\.0/).size

    run_window(runner, 60)
    assert_equal 1, @log.string.scan("sim balance").size, "다음 600초 경계 전에는 또 남기지 않는다"
  end

  test "Tick 과 Inbound 가 예외를 던져도 서로와 Logistics 와 Flusher 는 계속된다" do
    order = []
    logistics = RecordingLogistics.new
    runner = Simulation::Runner.new(logger: Logger.new(@log), logistics: logistics,
                                    ops_tick: RecordingStep.new(:tick, order, error: RuntimeError.new("tick boom")),
                                    inbound: RecordingStep.new(:inbound, order, error: RuntimeError.new("inbound boom")))

    7.times { |window| run_window(runner, window) }

    assert_equal 7, order.count { |name, _, _| name == :tick }
    assert_equal 7, order.count { |name, _, _| name == :inbound }, "Tick 이 터져도 Inbound 는 돈다"
    assert_equal [T0 + 60], logistics.calls, "둘 다 터져도 Logistics 는 60초 경계에서 돈다"
    assert_equal 7, ProductionEvent.count
    assert_equal 7, @log.string.scan(/sim ops tick failed .*RuntimeError tick boom/).size
    assert_equal 7, @log.string.scan(/sim inbound failed .*RuntimeError inbound boom/).size
  end

  test "Tick 과 Inbound 의 실패는 Flusher 의 재시도·폐기 흐름을 바꾸지 않는다" do
    order = []
    runner = Simulation::Runner.new(logger: Logger.new(@log), flusher: FlakyFlusher.new(fail_bucket: bucket(0), fail_times: 1),
                                    ops_tick: RecordingStep.new(:tick, order, error: RuntimeError.new("x")),
                                    inbound: RecordingStep.new(:inbound, order, error: RuntimeError.new("y")))

    2.times { |window| run_window(runner, window) }

    assert_equal [bucket(0), bucket(1)], ProductionEvent.order(:bucket_start).map(&:bucket_start)
    assert_equal [0, 2], order.select { |name, _, _| name == :tick }.map(&:last), "첫 경계는 flush 실패라 0, 다음 경계는 재시도로 2"
  end
end
