require "test_helper"
require "stringio"

# 8b 하드닝: 판단의 근거는 지워지지 않는 원장(stock_moves, inspections)이다. tasks 는 Task.prune! 으로 지워지고,
# 예약(reservations)은 작업이 지워질 때 함께 지워진다. 여기서는 그 위에서 K1(예약 존중)·K2(미검사량)·K3(상차 대상)·K4(실사 후보)를 확인한다.
class Inventory::ReservationHardeningTest < ActiveSupport::TestCase
  M0 = Time.utc(2026, 10, 8, 12, 0, 0)
  EPOCH = M0 - 3600
  WAIT = Simulation::Config::INSPECT_MAX_WAIT_SECONDS
  BIN = "RAW-A-01-01".freeze

  setup do
    @old_epoch = ENV["INVENTORY_EPOCH"]
    ENV["INVENTORY_EPOCH"] = EPOCH.iso8601
    Resource.ensure_defaults!
    Ops::Plan.reseed!(17)
    @now = Time.current.utc.change(usec: 0)
    @steel = Product.create!(sku: "RAW-HD", name: "하드닝강판", uom: "ea", kind: "raw")
    @fg = Product.create!(sku: "FG-HD", name: "하드닝브래킷", uom: "ea", kind: "fg")
    @seq = 0
    @log = StringIO.new
  end

  teardown do
    @old_epoch.nil? ? ENV.delete("INVENTORY_EPOCH") : ENV["INVENTORY_EPOCH"] = @old_epoch
  end

  def key = "hd-#{@seq += 1}"

  def stock(code, qty, product: @steel)
    Inventory::Move.call(product: product, lot: nil, from: "supplier", to: "receiving", qty: qty, move_type: "receive",
                         ref: nil, idempotency_key: key)
    Inventory::Move.call(product: product, lot: nil, from: "receiving", to: code, qty: qty, move_type: "putaway",
                         ref: nil, idempotency_key: key)
  end

  def feed_move(qty, **extra)
    Inventory::Move.call(product: @steel, lot: nil, from: BIN, to: "line_side", qty: qty, move_type: "feed", ref: nil,
                         idempotency_key: key, **extra)
  end

  def qty_at(code, product: @steel) = Quant.joins(:location).where(product_id: product.id, locations: { code: code }).sum(:qty).to_i

  def tick_all
    10.times do
      result = Ops::Tick.call(now: Time.current + 1.day)
      break if result.done.empty? && result.cancelled.empty?
    end
  end

  # --- K1: Inventory::Move 의 예약 존중 -------------------------------------------------------------

  test "K1: 예약된 칸에서는 예약 밖 수량만 이동할 수 있다" do
    stock(BIN, 100)
    Ops::Plan.call(kind: "feed", product: @steel, lot: nil, qty: 60, from: BIN, to: "line_side", ref: nil, earliest_at: @now)

    assert_raises(Inventory::InsufficientStock) { feed_move(50) } # 100 - 예약 60 = 40 < 50
    assert_equal 100, qty_at(BIN)
    assert_equal 0, StockMove.where(move_type: "feed").count

    feed_move(40) # 예약 밖 수량은 나간다
    assert_equal [60, 40], [qty_at(BIN), qty_at("line_side")]
  end

  test "K1: 작업 자신의 완료 이동은 자기 예약 안에서 성공한다(다른 작업 예약 60 + 자기 40 = 재고 100)" do
    stock(BIN, 100)
    a = Ops::Plan.call(kind: "feed", product: @steel, lot: nil, qty: 60, from: BIN, to: "line_side", ref: nil, earliest_at: @now)
    b = Ops::Plan.call(kind: "feed", product: @steel, lot: nil, qty: 40, from: BIN, to: "line_side", ref: nil, earliest_at: @now)

    tick_all

    assert_equal %w[done done], [a, b].map { |t| t.reload.status }
    assert_equal [0, 100], [qty_at(BIN), qty_at("line_side")]
    assert_equal %w[consumed consumed], Reservation.order(:id).pluck(:status)
  end

  test "K1: 자기 예약을 명시(reserved_by_task_id)하면 그 작업 몫은 빼고 계산한다. 다른 작업 id 를 주면 막힌다" do
    stock(BIN, 100)
    task = Ops::Plan.call(kind: "feed", product: @steel, lot: nil, qty: 80, from: BIN, to: "line_side", ref: nil, earliest_at: @now)

    assert_raises(Inventory::InsufficientStock) { feed_move(80, reserved_by_task_id: task.id + 1) }
    feed_move(80, reserved_by_task_id: task.id)

    assert_equal [20, 80], [qty_at(BIN), qty_at("line_side")]
  end

  test "K1: 다른 작업 예약 때문에 완료 이동이 막히면 작업만 취소되고 재고는 그대로다" do
    stock(BIN, 100)
    task = Ops::Plan.call(kind: "feed", product: @steel, lot: nil, qty: 60, from: BIN, to: "line_side", ref: nil, earliest_at: @now)
    # 예약 합이 재고를 넘는 상태를 만든다(Plan 의 확인을 거치지 않은 경로): 자원 없는 다른 작업의 예약 70 + 이 작업 60 > 100.
    # 자원이 없어 Tick 이 건드리지 않으므로 처리 순서와 상관없이 이 작업만 막힌다.
    other = Task.create!(kind: "feed", status: "planned", product: @steel, lot: nil, qty: 70, planned_at: @now,
                         from_location: Location.find_by!(code: BIN), to_location: Location.find_by!(code: "line_side"))
    Reservation.create!(task: other, product: @steel, lot: nil, location: Location.find_by!(code: BIN), qty: 70, status: "active")

    Ops::Tick.call(now: Time.current + 1.day)

    assert_equal "cancelled", task.reload.status
    assert_match(/InsufficientStock/, task.cancel_reason)
    assert_equal 100, qty_at(BIN)
  end

  # --- K2: 미검사량은 inspections 원장 기준 ---------------------------------------------------------

  def inspection_setup
    PutawayRule.create!(product: nil, location: Location.find_by!(code: "fg_store"), priority: 50)
    machine = Machine.create!(code: "M1", name: "절단기", state: "running")
    @order = WorkOrder.create!(code: "WO-HD1", machine: machine, item: @fg, product: "브래킷", target_qty: 100_000,
                               status: "active", started_at: M0)
    ProductionEvent.create!(machine: machine, work_order: @order, bucket_start: M0 - 600, bucket_end: M0 - 590,
                            good_qty: 90, defect_qty: 10, machine_version: 0)
  end

  def produce_to_qc(qty, at)
    lot = Lot.find_or_create_by!(product: @fg, lot_no: @order.code)
    Inventory::Move.call(product: @fg, lot: lot, from: "production", to: "qc", qty: qty, move_type: "produce",
                         ref: @order, idempotency_key: "produce:#{@order.id}:#{at.utc.iso8601}")
  end

  def inspect_plan(now = M0) = Simulation::Inspection.call(now: now, logger: Logger.new(@log))

  def uninspected
    qc = Location.find_by!(code: "qc")
    Simulation::Inspection.new(now: M0, logger: Logger.new(@log)).send(:uninspected_by_order, qc, [@order.id]).fetch(@order.id, 0).to_i
  end

  test "K2: 검사가 모두 끝난 뒤 Task.prune! 으로 tasks 가 지워져도 미검사량은 변하지 않는다" do
    inspection_setup
    produce_to_qc(100, M0 - WAIT)
    inspect_plan
    tick_all
    inspect_plan
    tick_all
    assert_equal 100, Inspection.where(work_order_id: @order.id).sum(:qty).to_i, "불량 10 + 합격 90 이 원장에 남았다"
    produce_to_qc(40, M0 - 10)
    before = uninspected
    assert_equal 40, before

    deleted = Task.prune!(before: Time.current + 2.days)

    assert_operator deleted, :>, 0
    assert_equal 0, Task.where(kind: "inspect").count, "prune 이 실제로 검사 작업을 지웠다"
    assert_equal before, uninspected
  end

  test "K2: 진행 중(planned/started) 검사는 tasks 에서 더해 같은 수량을 또 계획하지 않는다" do
    inspection_setup
    produce_to_qc(100, M0 - WAIT)
    assert_equal 1, inspect_plan[:inspect]

    assert_equal 0, uninspected
    assert_equal 0, inspect_plan[:inspect]
  end

  test "K2: 검사 행에는 이동 수량이 qty 로 남는다" do
    inspection_setup
    produce_to_qc(100, M0 - WAIT)
    inspect_plan
    tick_all
    inspect_plan
    tick_all

    rows = Inspection.where(work_order_id: @order.id).order(:result).pluck(:result, :qty).map { |r, q| [r, q.to_i] }
    assert_equal [["fail", 10], ["pass", 90]], rows
  end

  # --- K3: 상차 대상은 shipping 실재고 − 열린 load -------------------------------------------------

  def ship_plan = Simulation::Shipping.call(now: M0, logger: Logger.new(@log))

  test "K3: pick 이 모두 끝나 Task.prune! 으로 지워져도 shipping 에 있는 재고는 load 대상이다. 열린 load 분은 빼고, 주문 잔량으로 자른다" do
    lot = Lot.create!(product: @fg, lot_no: "LOT-HD-SH")
    ordered = (5 * Simulation::Config::PICK_QTY) / 2 # pick 단위 2.5 개분. 재고도 같은 양이라 pick 이 끝나면 fg 칸이 빈다
    Inventory::Move.call(product: @fg, lot: lot, from: "production", to: "qc", qty: ordered, move_type: "produce", ref: nil, idempotency_key: key)
    Inventory::Move.call(product: @fg, lot: lot, from: "qc", to: "FG-A-01-01", qty: ordered, move_type: "qc_pass", ref: nil, idempotency_key: key)
    so = SalesOrder.create!(so_no: "SO-HD-1", customer: "한빛정공", due_date: Date.new(2026, 10, 10), status: "open")
    line = so.lines.create!(product: @fg, ordered_qty: ordered)
    ship_plan
    tick_all
    assert_equal ordered, Task.where(kind: "pick", status: "done").sum(:qty).to_i, "pick 이 모두 끝났다"
    assert_equal ordered, Quant.joins(:location).where(locations: { code: "shipping" }).sum(:qty).to_i

    Task.prune!(before: Time.current + 2.days)
    assert_equal 0, Task.where(kind: "pick").count, "pick 기록이 지워졌다"

    assert_equal 1, ship_plan[:load]
    load_task = Task.where(kind: "load").sole
    assert_equal [line.id, lot.id, ordered], [load_task.ref_id, load_task.lot_id, load_task.qty.to_i]
    assert_equal 0, ship_plan[:load], "열린 load 분은 빼므로 같은 재고로 또 계획하지 않는다"

    tick_all
    assert_equal "done", load_task.reload.status
    assert_equal ordered, StockMove.where(move_type: "ship", ref_type: "SalesOrderLine", ref_id: line.id).sum(:qty).to_i
    assert_equal [], Inventory::Reconcile.call
  end

  # --- K4: 실사 후보 -------------------------------------------------------------------------------

  def count_plan(now) = Ops::CycleCount.call(now: now, logger: Logger.new(@log))

  test "K4: 열린 feed/pick/load/putaway 가 걸린 칸은 실사 후보에서 뺀다" do
    stock("RAW-A-01-01", 100)
    stock("RAW-A-01-02", 100)
    Ops::Plan.call(kind: "feed", product: @steel, lot: nil, qty: 10, from: "RAW-A-01-01", to: "line_side", ref: nil, earliest_at: @now)

    assert_equal 1, count_plan(@now)
    assert_equal "RAW-A-01-02", Task.where(kind: "count").sole.from_location.code, "01 칸은 열린 feed 의 출발지라 02 를 센다"
  end

  test "K4: 도착지로 걸린 칸과 후보가 그 칸뿐일 때는 실사를 계획하지 않는다" do
    stock("RAW-A-01-01", 100)
    Ops::Plan.call(kind: "putaway", product: @steel, lot: nil, qty: 10, from: "RAW-A-01-01", to: "RAW-A-01-02", ref: nil, earliest_at: @now)
    stock("RAW-A-01-02", 20)

    assert_equal 0, count_plan(@now), "01 은 putaway 출발지, 02 는 도착지"
    assert_equal 0, Task.where(kind: "count").count
  end

  test "K4: 실사 완료는 그 칸 quant 를 FOR UPDATE 로 잠근 뒤 읽는다" do
    stock(BIN, 100)
    assert_equal 1, count_plan(@now)
    task = Task.where(kind: "count").sole
    sqls = []
    subscriber = ->(*, payload) { sqls << payload[:sql] if payload[:sql].include?('FROM "quants"') }

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      Ops::CycleCount.complete(task, at: @now)
    end

    assert(sqls.any? { |sql| sql.include?("FOR UPDATE") }, "quants 읽기에 FOR UPDATE 가 없다: #{sqls.inspect}")
  end
end
