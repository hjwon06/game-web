require "test_helper"

class FlusherTest < ActiveSupport::TestCase
  BUCKET = Time.utc(2026, 10, 6, 12, 0, 0)

  setup do
    @m1 = Machine.create!(code: "M1", name: "절단기", state: "running")
    @m2 = Machine.create!(code: "M2", name: "조립기", state: "running")
    @order1 = make_order(@m1, "WO-1", 100, "active")
    @order2 = make_order(@m2, "WO-2", 100, "active")
    @acc = Simulation::Accumulator.new
    @rng = Random.new(Simulation::Config::SEED)
  end

  def make_order(machine, code, target, status)
    WorkOrder.create!(code: code, machine: machine, product: "브래킷", target_qty: target, status: status,
                      started_at: (Time.current if status == "active"))
  end

  def tick_seconds(count)
    snapshot = Machine.order(:id).pluck(:code, :state, :version).map { |c, s, v| { code: c, state: s, version: v } }
    count.times { @acc.tick(snapshot, @rng) }
  end

  def stop_via_command(machine)
    MachineCommand.call(idempotency_key: SecureRandom.uuid, machine_code: machine.code, kind: "stop",
                        base_version: machine.reload.version)
  end

  def start_via_command(machine)
    MachineCommand.call(idempotency_key: SecureRandom.uuid, machine_code: machine.code, kind: "start",
                        base_version: machine.reload.version)
  end

  test "정상 flush 는 기계당 1행을 쓰고 produced_qty 를 올린다" do
    tick_seconds(10)
    expected = @acc.entry("M1").good_qty
    expected_defect = @acc.entry("M1").defect_qty
    assert_operator expected, :>, 0

    assert_equal 2, Simulation::Flusher.call(@acc, BUCKET)

    event = ProductionEvent.find_by!(machine: @m1)
    assert_equal [BUCKET, BUCKET + 10, expected, expected_defect],
                 [event.bucket_start, event.bucket_end, event.good_qty, event.defect_qty]
    assert_equal @order1.id, event.work_order_id
    assert_equal expected, @order1.reload.produced_qty
    assert_empty @acc.entries, "커밋 뒤 누적기는 비워진다"
  end

  test "같은 bucket 을 두 번 flush 해도 행은 1개고 produced_qty 는 한 번만 오른다" do
    tick_seconds(10)
    first_good = @acc.entry("M1").good_qty
    Simulation::Flusher.call(@acc, BUCKET)

    tick_seconds(10)
    assert_equal 0, Simulation::Flusher.call(@acc, BUCKET)

    assert_equal 1, ProductionEvent.where(machine: @m1).count
    assert_equal first_good, @order1.reload.produced_qty
  end

  test "구간 중 정지 명령이 있었으면 그 구간 행은 0이다" do
    tick_seconds(5)
    stop_via_command(@m1)
    tick_seconds(5)
    Simulation::Flusher.call(@acc, BUCKET)

    assert_equal 0, ProductionEvent.where(machine: @m1).count
    assert_equal 0, @order1.reload.produced_qty
    assert_equal 1, ProductionEvent.where(machine: @m2).count
  end

  test "정지 뒤 곧바로 재가동해 state 가 running 이어도 version 이 달라 행은 0이다" do
    tick_seconds(5)
    stop_via_command(@m1)
    start_via_command(@m1)
    assert_equal "running", @m1.reload.state
    Simulation::Flusher.call(@acc, BUCKET)

    assert_equal 0, ProductionEvent.where(machine: @m1).count
  end

  test "active 작업지시가 없으면 행은 0이다" do
    @order1.update!(status: "done")
    tick_seconds(10)
    Simulation::Flusher.call(@acc, BUCKET)

    assert_equal 0, ProductionEvent.where(machine: @m1).count
    assert_equal 1, ProductionEvent.where(machine: @m2).count
  end

  test "목표에 도달하면 done 이 되고 가장 오래된 queued 가 active 가 된다" do
    @order1.update!(target_qty: 1)
    older = make_order(@m1, "WO-3", 100, "queued")
    newer = make_order(@m1, "WO-4", 100, "queued")
    older.update_columns(created_at: 2.days.ago)
    tick_seconds(10)

    Simulation::Flusher.call(@acc, BUCKET)

    assert_equal "done", @order1.reload.status
    assert_not_nil @order1.finished_at
    assert_equal "active", older.reload.status
    assert_not_nil older.started_at
    assert_equal "queued", newer.reload.status
  end

  test "flusher 는 machines.state 와 version 을 바꾸지 않는다" do
    tick_seconds(10)
    assert_no_changes -> { Machine.order(:id).pluck(:state, :version) } do
      Simulation::Flusher.call(@acc, BUCKET)
    end
  end
end
