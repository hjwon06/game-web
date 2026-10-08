require "test_helper"
require "stringio"

# Logistics 의 신규 수주 단계와 단계 격리. 검사는 inspection_test.rb, 출하는 shipping_test.rb 로 옮겼다.
class LogisticsFulfillmentTest < ActiveSupport::TestCase
  include UnscaledRatesHelper
  M0 = Time.utc(2026, 10, 8, 12, 0, 0)
  EPOCH = M0 - 3600

  setup do
    @old_epoch = ENV["INVENTORY_EPOCH"]
    ENV["INVENTORY_EPOCH"] = EPOCH.iso8601
    @fg = Product.create!(sku: "FG-BR", name: "브래킷", uom: "ea", kind: "fg")
    @machine = Machine.create!(code: "M1", name: "절단기", state: "running")
    @order = WorkOrder.create!(code: "WO-F1", machine: @machine, item: @fg, product: "브래킷", target_qty: 100_000,
                               status: "active", started_at: M0)
    @log = StringIO.new
  end

  teardown do
    @old_epoch.nil? ? ENV.delete("INVENTORY_EPOCH") : ENV["INVENTORY_EPOCH"] = @old_epoch
  end

  def run_minute(n)
    Simulation::Logistics.call(now: M0 + (n * 60), logger: Logger.new(@log))
  end

  test "Logistics 는 검사·출하를 하지 않는다: qc 와 fg 재고가 있어도 qc_pass·qc_fail·pick·ship 이동이 없다" do
    lot = Lot.find_or_create_by!(product: @fg, lot_no: @order.code)
    Inventory::Move.call(product: @fg, lot: lot, from: "production", to: "qc", qty: 100, move_type: "produce", ref: @order,
                         idempotency_key: "produce:#{@order.id}:#{(M0 - 600).iso8601}")
    so = SalesOrder.create!(so_no: "SO-T-1", customer: "한빛정공", due_date: Date.new(2026, 10, 1), status: "open")
    so.lines.create!(product: @fg, ordered_qty: 10)

    5.times { |n| run_minute(n) }

    %w[qc_pass qc_fail pick ship].each { |type| assert_equal 0, StockMove.where(move_type: type).count, type }
    assert_equal 0, Task.count
  end

  test "신규 수주는 10분에 1건이고 같은 분 재실행으로 늘지 않는다" do
    run = (0..9).map { |n| run_minute(n)[:order] }

    assert_equal [1, 0, 0, 0, 0, 0, 0, 0, 0, 0], run
    assert_equal 1, SalesOrder.count
    assert_equal 0, run_minute(0)[:order], "같은 분 재실행"
    assert_equal 1, SalesOrder.count

    assert_equal 1, run_minute(10)[:order]
    assert_equal 2, SalesOrder.count
  end

  test "신규 수주 모양: 연번 so_no, 고객 순환, 라인 1~2, 납기 1~3일" do
    4.times { |i| run_minute(i * 10) }

    orders = SalesOrder.order(:id).to_a
    assert_equal %w[SO-2610-001 SO-2610-002 SO-2610-003 SO-2610-004], orders.map(&:so_no)
    assert_equal Simulation::Config::CUSTOMERS, orders.map(&:customer)
    orders.each_with_index do |o, i|
      assert_includes 1..2, o.lines.count
      assert_includes 1..3, (o.due_date - (M0 + (i * 600)).to_date).to_i
      o.lines.each { |l| assert_equal @fg.id, l.product_id }
    end
  end

  test "신규 수주 수량은 시간당 양품 생산량의 0.5~2배다" do
    run_minute(0)

    hourly = 0.8 * (1 - 0.02) * 3600
    qty = SalesOrderLine.first.ordered_qty
    assert_operator qty, :>=, (hourly * 0.5).floor
    assert_operator qty, :<=, (hourly * 2).ceil
  end

  test "진행 중 작업지시가 없으면 신규 수주도 없다" do
    @order.update!(status: "done")
    assert_equal 0, run_minute(0)[:order]
  end

  test "catch_up 이 터져도 신규 수주는 실행되고 실패는 로그 1줄이다" do
    original = Simulation::Logistics.instance_method(:catch_up)
    Simulation::Logistics.send(:define_method, :catch_up) { |*| raise "catch_up 실패" }
    begin
      result = run_minute(0)
    ensure
      Simulation::Logistics.send(:define_method, :catch_up, original)
    end

    assert_equal 1, result[:order]
    assert_equal 1, @log.string.lines.grep(/sim logistics backflush .*catch_up 실패/).size
  end

  test "한 단계의 PG 오류는 그 단계만 되돌리고 다음 단계는 정상이다" do
    original = Simulation::Logistics.instance_method(:catch_up)
    Simulation::Logistics.send(:define_method, :catch_up) do |*|
      Quant.insert_all([{ product_id: -1, location_id: -1, qty: 1 }]) # 없는 FK → PG 오류, 트랜잭션 aborted
    end
    begin
      result = run_minute(0)
    ensure
      Simulation::Logistics.send(:define_method, :catch_up, original)
    end

    assert_equal 1, result[:order], "뒤 단계는 aborted 트랜잭션에 걸리지 않는다"
    assert_equal 1, SalesOrder.count
    assert_equal 1, @log.string.lines.grep(/sim logistics backflush .*ForeignKey/).size
    assert_equal 1, @log.string.lines.grep(/ERROR/).size
  end

  test "이어서 돌려도 물리 위치가 마이너스가 되지 않고 Reconcile 이 0 이다" do
    ProductionEvent.create!(machine: @machine, work_order: @order, bucket_start: M0 - 600, bucket_end: M0 - 590,
                            good_qty: 90, defect_qty: 10, machine_version: 0)
    (0..4).each { |n| run_minute(n) }

    assert_equal 0, Quant.joins(:location).where(locations: { kind: "physical" }).where("quants.qty < 0").count
    assert_equal [], Inventory::Reconcile.call
  end
end
