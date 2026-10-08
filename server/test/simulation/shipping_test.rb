require "test_helper"
require "stringio"

# 출하: 열린 수주 라인마다 fg 칸 재고가 있으면 pick(지게차, 100개 단위, FIFO 칸 → shipping),
# 라인의 pick 이 끝나 shipping 에 모이면 load(출하 도크, shipping → customer). 부분 출하 허용.
class ShippingTest < ActiveSupport::TestCase
  include UnlimitedForkliftQueueHelper
  M0 = Time.utc(2026, 10, 8, 12, 0, 0)

  setup do
    Resource.ensure_defaults!
    Ops::Plan.reseed!(3)
    @fg = Product.create!(sku: "FG-BR", name: "브래킷", uom: "ea", kind: "fg")
    @log = StringIO.new
    @seq = 0
  end

  def plan(now = M0) = Simulation::Shipping.call(now: now, logger: Logger.new(@log))

  U = Simulation::Config::PICK_QTY # pick 1건의 단위

  # Tick 1회는 자원당 1건만 끝내므로(D2) 밀린 작업이 없어질 때까지 반복한다.
  def tick
    10.times do
      result = Ops::Tick.call(now: Time.current + 1.day)
      break if result.done.empty? && result.cancelled.empty?
    end
  end

  # fg 칸에 재고를 만든다(생산 → 검사대 → 합격 적치 완료 상태).
  def fg_stock(qty, bin: "FG-A-01-01", lot: nil, created_at: nil)
    lot ||= Lot.create!(product: @fg, lot_no: "LOT-#{@seq += 1}", **(created_at ? { created_at: created_at, updated_at: created_at } : {}))
    Inventory::Move.call(product: @fg, lot: lot, from: "production", to: "qc", qty: qty, move_type: "produce", ref: nil,
                         idempotency_key: "sh-prod-#{@seq += 1}")
    Inventory::Move.call(product: @fg, lot: lot, from: "qc", to: bin, qty: qty, move_type: "qc_pass", ref: nil,
                         idempotency_key: "sh-pass-#{@seq += 1}")
    lot
  end

  def line_for(so_no, qty, due: Date.new(2026, 10, 10))
    so = SalesOrder.create!(so_no: so_no, customer: "한빛정공", due_date: due, status: "open")
    so.lines.create!(product: @fg, ordered_qty: qty)
  end

  def picks = Task.where(kind: "pick").order(:id)

  def loads = Task.where(kind: "load").order(:id)

  def qty_at(code, lot = nil)
    Quant.joins(:location).where(product_id: @fg.id, locations: { code: code }).then { |q| lot ? q.where(lot_id: lot.id) : q }.sum(:qty)
  end

  def shipped(line) = StockMove.where(move_type: "ship", ref_type: "SalesOrderLine", ref_id: line.id).sum(:qty).to_i

  test "열린 수주 라인에 fg 칸 재고가 있으면 PICK_QTY 단위 pick 이 지게차에 계획된다. 재고는 아직 안 움직인다" do
    lot = fg_stock(3 * U)
    line = line_for("SO-T-1", (5 * U) / 2)
    base = StockMove.count

    result = plan

    assert_equal [3, 0], [result[:pick], result[:load]]
    assert_equal [U, U, U / 2], picks.map { |t| t.qty.to_i }
    picks.each do |t|
      assert_equal ["forklift", "FG-A-01-01", "shipping", lot.id, "SalesOrderLine", line.id, "planned"],
                   [t.resource.kind, t.from_location.code, t.to_location.code, t.lot_id, t.ref_type, t.ref_id, t.status]
    end
    assert_equal base, StockMove.count
  end

  test "FIFO: 로트가 오래된 칸에서 먼저 나간다. 로트 시각이 같으면 칸 코드 순" do
    old_lot = fg_stock(100, bin: "FG-A-01-02", created_at: M0 - 7200)
    fg_stock(100, bin: "FG-A-01-01", created_at: M0 - 3600)
    line_for("SO-T-1", 100)

    plan

    task = picks.sole
    assert_equal ["FG-A-01-02", old_lot.id], [task.from_location.code, task.lot_id]
  end

  test "로트 시각이 같으면 칸 코드가 앞선 칸에서 나간다" do
    same = M0 - 3600
    fg_stock(100, bin: "FG-A-01-02", created_at: same)
    first = fg_stock(100, bin: "FG-A-01-01", created_at: same)
    line_for("SO-T-1", 100)

    plan

    assert_equal ["FG-A-01-01", first.id], picks.sole.then { |t| [t.from_location.code, t.lot_id] }
  end

  test "재고가 모자라면 있는 만큼만 pick 한다(부분 출하)" do
    fg_stock(U + 20)
    line_for("SO-T-1", 3 * U)

    plan

    assert_equal [U, 20], picks.map { |t| t.qty.to_i }
  end

  test "D5: 같은 칸에서 가져가려는 다른 미완료 작업(pick 이 아니어도)이 잡은 수량은 빼고 pick 한다" do
    lot = fg_stock(U)
    line = line_for("SO-T-1", U)
    # 같은 칸·품목·로트에서 400 을 이미 잡은 작업(합격 적치처럼 pick 이 아닌 종류)
    Ops::Plan.call(kind: "putaway", product: @fg, lot: lot, qty: 400, from: "FG-A-01-01", to: "FG-A-01-02", ref: nil, earliest_at: M0)

    plan

    assert_equal [U - 400], picks.map { |t| t.qty.to_i }, "재고 #{U} 중 400 은 이미 잡혀 있다"
    assert_equal [line.id], picks.map(&:ref_id)
    held = Reservation.held.fetch([Location.find_by!(code: "FG-A-01-01").id, @fg.id, lot.id])
    assert_equal U, held, "잡힌 합계(active 예약)가 재고를 넘지 않는다"

    assert_equal 0, plan[:pick], "다시 불러도 같은 재고를 또 잡지 않는다"
  end

  test "같은 품목 재고를 두 라인이 나눠 쓸 때 이미 계획된 pick 분은 다시 계획하지 않는다" do
    fg_stock(150)
    a = line_for("SO-T-A", 100, due: Date.new(2026, 10, 9))
    b = line_for("SO-T-B", 100, due: Date.new(2026, 10, 11))

    plan

    assert_equal [[a.id, 100], [b.id, 50]], picks.map { |t| [t.ref_id, t.qty.to_i] }
  end

  test "납기가 빠른 수주 라인이 재고를 먼저 받는다" do
    fg_stock(100)
    late = line_for("SO-T-LATE", 100, due: Date.new(2026, 10, 12))
    early = line_for("SO-T-EARLY", 100, due: Date.new(2026, 10, 9))

    plan

    assert_equal [early.id], picks.map(&:ref_id)
    assert_not_includes picks.map(&:ref_id), late.id
  end

  test "재고가 없으면 아무것도 계획하지 않는다. 다 출하된 수주(done)도 건드리지 않는다" do
    line_for("SO-T-1", 100)
    assert_equal [0, 0], plan.values_at(:pick, :load)

    fg_stock(100)
    SalesOrder.update_all(status: "done")
    assert_equal [0, 0], plan.values_at(:pick, :load)
    assert_equal 0, Task.count
  end

  test "같은 시각에 다시 불러도 작업·이동이 늘지 않는다" do
    fg_stock(3 * U)
    line_for("SO-T-1", (5 * U) / 2)
    plan
    tasks = Task.count
    moves = StockMove.count

    again = plan

    assert_equal [0, 0], again.values_at(:pick, :load)
    assert_equal tasks, Task.count
    assert_equal moves, StockMove.count
  end

  test "pick 이 진행 중인 라인은 load 하지 않고, 모두 끝나 shipping 에 모이면 load 1건을 계획한다" do
    lot = fg_stock(3 * U)
    line = line_for("SO-T-1", 3 * U)
    plan

    assert_equal 0, plan[:load], "pick 이 아직 planned"
    assert_equal 0, loads.count

    tick
    assert_equal %w[done done done], picks.map(&:status)
    assert_equal [0, 3 * U], [qty_at("FG-A-01-01"), qty_at("shipping")]
    assert_equal 3, StockMove.where(move_type: "pick").count

    result = plan
    assert_equal [1, 0], result.values_at(:load, :pick)
    load_task = loads.sole
    assert_equal ["dock_out", "shipping", "customer", 3 * U, lot.id, "SalesOrderLine", line.id],
                 [load_task.resource.kind, load_task.from_location.code, load_task.to_location.code, load_task.qty.to_i,
                  load_task.lot_id, load_task.ref_type, load_task.ref_id]
    assert_equal 0, plan[:load], "같은 시각 재실행은 load 를 또 만들지 않는다"
  end

  test "pick 여러 건 → load 1건 → ship 1건이고 수주가 done 이 된다" do
    fg_stock(3 * U)
    line = line_for("SO-T-1", 3 * U)
    plan
    tick
    plan

    tick

    assert_equal "done", loads.sole.status
    ship = StockMove.where(move_type: "ship").sole
    assert_equal ["shipping", "customer", 3 * U, "SalesOrderLine", line.id, "task:#{loads.sole.id}"],
                 [ship.from_location.code, ship.to_location.code, ship.qty.to_i, ship.ref_type, ship.ref_id, ship.idempotency_key]
    assert_equal "done", line.sales_order.reload.status
    assert_equal [0, 0, 3 * U], [qty_at("FG-A-01-01"), qty_at("shipping"), qty_at("customer")]
    assert_equal [], Inventory::Reconcile.call
  end

  test "6d: pick 한 양이 주문 잔량보다 많으면 load 는 주문 잔량(14)만 계획한다" do
    fg_stock(100)
    line = line_for("SO-T-1", 100)
    plan
    tick
    line.update_columns(ordered_qty: 14) # pick 이 끝난 뒤 주문량이 줄었다

    plan

    assert_equal [14], loads.map { |t| t.qty.to_i }
    tick
    assert_equal [0, "done"], [loads.where(status: "cancelled").count, loads.sole.status]
    assert_equal 14, shipped(line)
  end

  test "6d: 주문 잔량이 0 이면 load 를 계획하지 않는다" do
    # ordered_qty 는 DB 체크(> 0)라 0 으로 만들 수 없다. 주문량만큼 다 출하해 잔량 0 을 만든다(pick 은 100, 주문 14).
    fg_stock(100)
    line = line_for("SO-T-1", 100)
    plan
    tick
    line.update_columns(ordered_qty: 14)
    plan
    tick
    assert_equal 14, shipped(line)

    assert_equal 0, plan[:load], "잔량 0 — pick 해 둔 86 이 남아 있어도 load 를 더 만들지 않는다"
    assert_equal 1, loads.count
    assert_equal 0, loads.where(status: "cancelled").count
  end

  test "6c: pick 이동의 ref 는 수주 라인이고 멱등 키는 task:<id> 그대로다" do
    fg_stock(U)
    line = line_for("SO-T-1", U)
    plan
    tick

    move = StockMove.where(move_type: "pick").sole
    assert_equal ["SalesOrderLine", line.id, "task:#{picks.sole.id}"], [move.ref_type, move.ref_id, move.idempotency_key]
  end

  test "6c: 수주 A 가 피킹한 재고가 출하대에 있어도 수주 B 의 load 는 만들어지지 않는다" do
    fg_stock(U)
    a = line_for("SO-T-A", U, due: Date.new(2026, 10, 9))
    plan
    tick
    b = line_for("SO-T-B", U, due: Date.new(2026, 10, 8)) # 납기가 더 빨라도 B 는 피킹한 적이 없다
    assert_equal U, qty_at("shipping")

    result = plan

    assert_equal 1, result[:load]
    assert_equal [a.id], loads.map(&:ref_id), "출하대 재고는 A 의 피킹분이라 A 만 싣는다"
    tick
    assert_equal [U, 0], [shipped(a), shipped(b)]
  end

  test "6c: 라인별 상차 가능량 = 그 라인 pick 합 - ship 합 - 열린 load 합. 다른 라인 몫은 넘보지 않는다" do
    fg_stock(300)
    a = line_for("SO-T-A", 200, due: Date.new(2026, 10, 9))
    b = line_for("SO-T-B", 100, due: Date.new(2026, 10, 10))
    plan
    tick
    assert_equal [200, 100], picks.group(:ref_id).order(:ref_id).sum(:qty).values.map(&:to_i)

    plan
    assert_equal({ a.id => 200, b.id => 100 }, loads.group(:ref_id).sum(:qty).transform_values(&:to_i), "각자 피킹한 만큼만")
    assert_equal 0, plan[:load], "열린 load 분은 가능량에서 빠진다"

    tick
    assert_equal [200, 100], [shipped(a), shipped(b)]
    assert_equal 0, plan[:load]
  end

  test "6c: 옛 pick 이동(ref 가 수주 라인이 아님)은 수주를 몰라 상차 대상에서 뺀다" do
    lot = fg_stock(U)
    line = line_for("SO-T-1", U)
    Inventory::Move.call(product: @fg, lot: lot, from: "FG-A-01-01", to: "shipping", qty: U, move_type: "pick", ref: nil, idempotency_key: "old-pick")

    assert_equal 0, plan[:load], "출하대에 재고가 있어도 이 수주가 피킹했다는 원장 근거가 없다"
    assert_equal 0, loads.count
    assert_equal 0, shipped(line)
  end

  test "6c: 단계 누적 불변식 shipped <= loaded <= staged <= 주문량 — 여러 수주가 재고를 나눠 써도 유지된다" do
    fg_stock(3 * U)
    lines = [line_for("SO-T-A", U, due: Date.new(2026, 10, 9)), line_for("SO-T-B", 2 * U, due: Date.new(2026, 10, 10))]
    10.times do
      plan
      tick
      lines.each do |line|
        ledger = ->(type) { StockMove.where(move_type: type, ref_type: "SalesOrderLine", ref_id: line.id).sum(:qty) }
        started = Task.where(kind: "load", status: %w[started done], ref_type: "SalesOrderLine", ref_id: line.id).sum(:qty)
        assert_operator ledger.("ship"), :<=, started
        assert_operator started, :<=, ledger.("pick")
        assert_operator ledger.("pick"), :<=, line.ordered_qty
      end
    end
    assert_equal [U, 2 * U], lines.map { |l| shipped(l) }
  end

  test "6d: 상차가 MAX 번 취소된 라인·로트는 더 계획하지 않고 포기 로그는 1줄만 남긴다" do
    fg_stock(100)
    line_for("SO-T-1", 100)
    plan
    tick
    Simulation::Shipping.gave_up.clear
    Simulation::Config::MAX_LOAD_CANCELS.times do
      plan
      loads.where(status: "planned").each { |t| t.update!(status: "cancelled", cancel_reason: "test") }
    end

    3.times { assert_equal 0, plan[:load] }
    assert_equal Simulation::Config::MAX_LOAD_CANCELS, loads.count
    assert_equal 1, @log.string.scan("더 계획하지 않음").size
  end

  test "로트가 둘이면 load 도 로트마다 1건이다" do
    a = fg_stock(100, bin: "FG-A-01-01", created_at: M0 - 7200)
    b = fg_stock(100, bin: "FG-A-01-02", created_at: M0 - 3600)
    line_for("SO-T-1", 200)
    plan
    tick

    plan

    assert_equal [[a.id, 100], [b.id, 100]], loads.map { |t| [t.lot_id, t.qty.to_i] }.sort
  end

  test "부분 출하: 재고만큼만 pick·load 해 partial 이 되고, 재고가 들어오면 이어서 done 이 된다" do
    first = U + 20
    rest = (3 * U) - first
    fg_stock(first)
    line = line_for("SO-T-1", 3 * U)
    plan
    tick
    plan
    tick
    assert_equal [first, "partial"], [shipped(line), line.sales_order.reload.status]
    assert_equal 0, plan[:pick], "재고가 없으면 새 pick 이 없다"

    fg_stock(rest)
    assert_equal 2, plan[:pick], "남은 #{rest} = #{U} + #{rest - U}"
    assert_equal [U, 20, U, rest - U], picks.map { |t| t.qty.to_i }
    tick
    plan
    tick

    assert_equal [3 * U, "done"], [shipped(line), line.sales_order.reload.status]
    assert_equal [], Inventory::Reconcile.call
    assert_equal 0, plan.values_at(:pick, :load).sum, "다 끝난 라인은 더 계획하지 않는다"
  end

  test "pick 이 취소되면 예약이 풀려 그만큼 다시 계획한다" do
    fg_stock(100)
    line_for("SO-T-1", 100)
    plan
    picks.sole.update!(status: "cancelled", cancel_reason: "test")

    assert_equal 1, plan[:pick]
    assert_equal %w[cancelled planned], picks.map(&:status)
    assert_equal %w[released active], Reservation.order(:id).pluck(:status)
  end

  test "FIFO 칸의 가용이 필요량보다 적으면 가용이 충분한 다음 로트에서 잡는다" do
    old_lot = fg_stock(100, bin: "FG-A-01-02", created_at: M0 - 7200)
    new_lot = fg_stock(100, bin: "FG-A-01-01", created_at: M0 - 3600)
    Ops::Plan.call(kind: "putaway", product: @fg, lot: old_lot, qty: 70, from: "FG-A-01-02", to: "FG-A-01-03", ref: nil, earliest_at: M0)
    line_for("SO-T-1", 100)

    plan

    # 오래된 로트는 30 만 가용(70 은 예약됨). 100 이 필요하므로 가용 100 이상인 다음 로트가 먼저 선택된다.
    assert_equal [[new_lot.id, 100]], picks.map { |t| [t.lot_id, t.qty.to_i] }
  end

  test "한 단계가 실패해도 다른 단계는 계속되고 실패는 로그에 남는다" do
    fg_stock(100)
    line_for("SO-T-1", 100)
    original = Simulation::Shipping.instance_method(:plan_loads)
    Simulation::Shipping.send(:define_method, :plan_loads) { raise "load 계획 실패" }
    begin
      result = plan
    ensure
      Simulation::Shipping.send(:define_method, :plan_loads, original)
    end

    assert_equal 1, result[:pick]
    assert_equal 1, @log.string.lines.grep(/sim shipping load .*load 계획 실패/).size
  end
end
