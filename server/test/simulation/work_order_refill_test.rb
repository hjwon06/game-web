require "test_helper"
require "stringio"

class WorkOrderRefillTest < ActiveSupport::TestCase
  BUCKET = Time.utc(2026, 10, 6, 12, 0, 0)
  Config = Simulation::Config

  setup do
    @log = StringIO.new
    @logger = Logger.new(@log)
    @machine = Machine.create!(code: "M1", name: "절단기", state: "running")
  end

  def make_order(machine, code, status, target: 100, product: "브래킷")
    WorkOrder.create!(code: code, machine: machine, product: product, target_qty: target, status: status,
                      started_at: (Time.current if status == "active"))
  end

  def expected_qty(code)
    ((Config.rate(code) * (1 - Config.defect_rate(code)) * 3600) / 100).round * 100
  end

  def finish_via_flusher(machine, order)
    order.update!(target_qty: 1)
    acc = Simulation::Accumulator.new
    rng = Random.new(Config::SEED)
    snapshot = Machine.order(:id).pluck(:code, :state, :version).map { |c, s, v| { code: c, state: s, version: v } }
    10.times { acc.tick(snapshot, rng) }
    Simulation::Flusher.call(acc, BUCKET)
  end

  test "작업지시가 끝나고 queued 가 없으면 같은 품목의 새 작업지시가 active 로 생긴다" do
    order = make_order(@machine, "WO-1001", "active")

    finish_via_flusher(@machine, order)

    assert_equal "done", order.reload.status
    fresh = WorkOrder.where(machine: @machine, status: "active").sole
    assert_equal "WO-1002", fresh.code
    assert_equal [order.product_id, order.product], [fresh.product_id, fresh.product]
    assert_equal expected_qty("M1"), fresh.target_qty, "rate x (1 - 불량률) x 3600 을 100 단위 반올림"
    assert_equal 0, fresh.produced_qty
    assert_not_nil fresh.started_at
  end

  test "수량 규칙: M1 은 0.264 x 0.98 x 3600 = 931 → 900" do
    assert_equal 900, Simulation::WorkOrderRefill.target_qty("M1")
    assert_equal expected_qty("M6"), Simulation::WorkOrderRefill.target_qty("M6")
    assert_operator Simulation::WorkOrderRefill.target_qty("M1"), :>=, 100
  end

  test "queued 가 있으면 새로 만들지 않고 queued 를 올린다" do
    order = make_order(@machine, "WO-1001", "active")
    queued = make_order(@machine, "WO-1002", "queued")
    before = WorkOrder.count

    finish_via_flusher(@machine, order)

    assert_equal before, WorkOrder.count
    assert_equal "active", queued.reload.status
  end

  test "번호는 WO-숫자 중 최대값 다음이고, 다른 접두 형식은 무시하며 중복되지 않는다" do
    make_order(@machine, "WO-2012", "done")
    make_order(@machine, "WO-P0099", "done")
    make_order(@machine, "WO-X", "done")
    other = Machine.create!(code: "M2", name: "조립기", state: "running")
    make_order(other, "WO-0007", "done")

    Simulation::WorkOrderRefill.sweep(logger: @logger)

    codes = WorkOrder.where(status: "active").order(:id).pluck(:code)
    assert_equal ["WO-2013", "WO-2014"], codes
    assert_equal WorkOrder.count, WorkOrder.distinct.count(:code)
  end

  test "sweep: running 인데 active 가 없으면 queued 를 올린다" do
    queued = make_order(@machine, "WO-1001", "queued")

    assert_equal 1, Simulation::WorkOrderRefill.sweep(logger: @logger)

    assert_equal "active", queued.reload.status
    assert_equal 1, WorkOrder.count
  end

  test "sweep: queued 도 없으면 마지막 작업지시 품목으로 새로 만든다" do
    make_order(@machine, "WO-1001", "done", product: "브래킷")
    last = make_order(@machine, "WO-1002", "done", product: "하우징")

    assert_equal 1, Simulation::WorkOrderRefill.sweep(logger: @logger)

    fresh = WorkOrder.where(machine: @machine, status: "active").sole
    assert_equal [last.product_id, "하우징", "WO-1003", expected_qty("M1")], [fresh.product_id, fresh.product, fresh.code, fresh.target_qty]
    assert_match(/sim refill M1 새 작업지시 WO-1003/, @log.string)
  end

  test "sweep: 이미 active 가 있으면 아무것도 하지 않는다" do
    make_order(@machine, "WO-1001", "active")

    assert_no_difference "WorkOrder.count" do
      assert_equal 0, Simulation::WorkOrderRefill.sweep(logger: @logger)
    end
  end

  test "sweep: 작업지시 이력이 전혀 없는 기계는 건너뛰고 로그를 남긴다" do
    assert_equal 0, Simulation::WorkOrderRefill.sweep(logger: @logger)

    assert_equal 0, WorkOrder.count
    assert_match(/sim refill M1 작업지시 이력이 없어 건너뜀/, @log.string)
  end

  test "sweep: stopped·broken 기계는 보충하지 않는다" do
    stopped = Machine.create!(code: "M2", name: "조립기", state: "stopped")
    broken = Machine.create!(code: "M3", name: "검사기", state: "broken")
    [stopped, broken].each_with_index { |m, i| make_order(m, "WO-30#{i}", "done") }
    make_order(@machine, "WO-1001", "active")

    assert_no_difference "WorkOrder.count" do
      assert_equal 0, Simulation::WorkOrderRefill.sweep(logger: @logger)
    end
  end

  test "Logistics 매분 호출이 놀고 있는 running 기계를 채운다" do
    make_order(@machine, "WO-1001", "done")

    Simulation::Logistics.call(now: BUCKET, logger: @logger)

    assert_equal ["WO-1002"], WorkOrder.where(machine: @machine, status: "active").pluck(:code)
  end

  test "Runner 는 기동 시 1회 놀고 있는 기계를 채운다" do
    make_order(@machine, "WO-1001", "done")
    runner = Simulation::Runner.new(logger: @logger)
    runner.stop!

    runner.run

    assert_equal ["WO-1002"], WorkOrder.where(machine: @machine, status: "active").pluck(:code)
  end
end
