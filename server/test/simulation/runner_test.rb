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
end
