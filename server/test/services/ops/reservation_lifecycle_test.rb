require "test_helper"

# 예약 생애: 계획 순간 active -> 완료 순간 consumed / 취소 순간 released. 작업 상태와 같은 트랜잭션이라 어긋나지 않는다.
class Ops::ReservationLifecycleTest < ActiveSupport::TestCase
  BIN = "RAW-A-01-01".freeze

  setup do
    Resource.ensure_defaults!
    Ops::Plan.reseed!(31)
    @steel = Product.create!(sku: "RAW-STEEL", name: "강판 시트", uom: "ea", kind: "raw")
    @t0 = Time.current.change(usec: 0) + 1.hour
    @seq = 0
  end

  def stock(qty, code: BIN, lot: nil)
    Inventory::Move.call(product: @steel, lot: lot, from: "supplier", to: "receiving", qty: qty, move_type: "receive",
                         ref: nil, idempotency_key: "rl-r-#{@seq += 1}")
    Inventory::Move.call(product: @steel, lot: lot, from: "receiving", to: code, qty: qty, move_type: "putaway",
                         ref: nil, idempotency_key: "rl-p-#{@seq += 1}")
  end

  def plan_feed(qty, lot: nil) = Ops::Plan.call(kind: "feed", product: @steel, lot: lot, qty: qty, from: BIN, to: "line_side", ref: nil, earliest_at: @t0)

  def reservation_of(task) = Reservation.find_by!(task_id: task.id)

  def available(qty = 1) = Ops::Removal.choose(product: @steel, qty: qty, from_scope: "raw_store", partial: true)&.available

  test "계획하면 from 칸의 (품목, 로트, 위치)로 active 예약이 작업과 함께 생긴다" do
    lot = Lot.create!(product: @steel, lot_no: "LOT-RL")
    stock(500, lot: lot)

    task = plan_feed(200, lot: lot)

    r = reservation_of(task)
    assert_equal ["active", @steel.id, lot.id, Location.find_by!(code: BIN).id, 200], [r.status, r.product_id, r.lot_id, r.location_id, r.qty.to_i]
    assert_equal 300, available, "가용 = 500 - 200"
    assert_equal 500, Quant.where(location: Location.find_by!(code: BIN)).sum(:qty), "계획만으로 재고는 안 움직인다"
  end

  test "from 이 가상 위치(supplier)인 작업은 예약이 없다. 물리 위치(receiving)면 있다" do
    unload = Ops::Plan.call(kind: "unload", product: @steel, lot: nil, qty: 100, from: "supplier", to: "receiving", ref: nil, earliest_at: @t0)
    Inventory::Move.call(product: @steel, lot: nil, from: "supplier", to: "receiving", qty: 100, move_type: "receive",
                         ref: nil, idempotency_key: "rl-recv-only") # 입고대에 100 (칸으로는 옮기지 않는다)
    put = Ops::Plan.call(kind: "putaway", product: @steel, lot: nil, qty: 100, from: "receiving", to: BIN, ref: nil, earliest_at: @t0)

    assert_nil Reservation.find_by(task_id: unload.id)
    assert_equal "receiving", reservation_of(put).location.code
  end

  test "예약 생성이 실패하면 작업도 남지 않는다(같은 트랜잭션)" do
    stock(500)
    Reservation.define_singleton_method(:create!) { |*| raise ActiveRecord::RecordInvalid }
    begin
      assert_raises(ActiveRecord::RecordInvalid) { plan_feed(10) }
    ensure
      Reservation.singleton_class.send(:remove_method, :create!) # 덮어쓴 것만 지워 원래 create! 로 돌아간다
    end

    assert_equal 0, Task.count
    assert_equal 0, Reservation.count
  end

  test "완료하면 consumed 가 되고 재고는 이동 1건만큼 줄어 가용이 현재고와 맞는다" do
    stock(500)
    task = plan_feed(200)

    Ops::Tick.call(now: task.planned_at)
    assert_equal "active", reservation_of(task).status, "시작만으로는 닫히지 않는다"
    Ops::Tick.call(now: task.expected_finish_at)

    assert_equal "done", task.reload.status
    assert_equal "consumed", reservation_of(task).status
    assert_equal 300, Quant.where(location: Location.find_by!(code: BIN)).sum(:qty)
    assert_equal 300, available, "예약이 닫혀 이중으로 깎이지 않는다(300 - 200 이 아니다)"
    assert_equal [], Inventory::Reconcile.call
  end

  test "재고 부족으로 취소되면 released 가 되고 그 재고를 다시 잡을 수 있다" do
    stock(500)
    task = plan_feed(400)
    # 계획 뒤에 이 계획을 거치지 않은 이동이 재고를 가져갔다(계획 시점 검증은 통과했다).
    Inventory::Move.call(product: @steel, lot: nil, from: BIN, to: "line_side", qty: 200, move_type: "feed",
                         ref: nil, idempotency_key: "rl-steal")
    assert_nil available, "예약 400 이 남은 재고 300 을 넘어 가용이 없다"

    Ops::Tick.call(now: task.planned_at)
    Ops::Tick.call(now: task.expected_finish_at)

    assert_equal "cancelled", task.reload.status
    assert_match(/InsufficientStock/, task.cancel_reason)
    assert_equal "released", reservation_of(task).status
    assert_equal 300, available
    assert_equal 0, StockMove.where(move_type: "feed", ref_type: "Task").count, "작업이 만든 feed 이동은 없다(수동 이동 1건만 있다)"
  end

  test "계획 시점에 가용(현재고 - active 예약)이 모자라면 InsufficientStock 이고 작업·예약이 남지 않는다" do
    stock(500)
    first = plan_feed(300)

    error = assert_raises(Inventory::InsufficientStock) { plan_feed(300) }

    assert_match(/가용 부족/, error.message)
    assert_equal [first.id], Task.pluck(:id)
    assert_equal [first.id], Reservation.pluck(:task_id)
    assert_equal 200, available, "실패한 계획이 예약을 남기지 않았다"
  end

  test "계획 시점에 도착 칸 자리(현재고 + 그 칸으로 가는 열린 작업)가 모자라면 CapacityExceeded 다" do
    stock(500)
    Location.where(code: "line_side").update_all(capacity_units: 400)
    first = plan_feed(300)

    assert_raises(Inventory::CapacityExceeded) { plan_feed(150) }
    assert_equal [first.id], Task.pluck(:id)
    assert_nothing_raised { plan_feed(100) }
  end

  test "이동이 실패하면 savepoint 와 함께 되돌아가 예약이 consumed 로 남지 않는다" do
    stock(500)
    cap = plan_feed(300)
    Location.where(code: "line_side").update_all(capacity_units: 100) # 용량 초과로 완료가 실패한다

    Ops::Tick.call(now: cap.planned_at)
    Ops::Tick.call(now: cap.expected_finish_at)

    assert_equal "cancelled", cap.reload.status
    assert_match(/CapacityExceeded/, cap.cancel_reason)
    assert_equal ["released"], Reservation.where(task_id: cap.id).pluck(:status)
    assert_equal 500, available
  end

  test "Tick 말고 다른 경로로 상태를 바꿔도 예약이 같이 닫힌다(done -> consumed, cancelled -> released)" do
    stock(500)
    a = plan_feed(100)
    b = plan_feed(100)

    a.update!(status: "cancelled", cancel_reason: "수동 취소")
    b.update!(status: "started", started_at: @t0)
    assert_equal "active", reservation_of(b).status, "started 는 닫지 않는다"
    b.update!(status: "done", finished_at: @t0 + 1.minute)

    assert_equal %w[released consumed], [reservation_of(a).status, reservation_of(b).status]
  end

  test "재시작해도(상태는 DB) active 예약이 남은 작업은 계속 유효하다: planned·started 어느 쪽이든" do
    stock(500)
    task = plan_feed(200)
    Ops::Plan.reseed!(99) # 프로세스가 다시 뜬 것처럼 메모리 상태를 버린다

    assert_equal 300, available, "새 프로세스도 같은 예약을 본다"
    Ops::Tick.call(now: task.planned_at - 1.second)
    assert_equal ["planned", "active"], [task.reload.status, reservation_of(task).status]

    Ops::Tick.call(now: task.planned_at)
    Ops::Plan.reseed!(100)
    Ops::Tick.call(now: task.planned_at + 1.second)
    assert_equal ["started", "active"], [task.reload.status, reservation_of(task).status], "started 도 유지"
    assert_equal 300, available

    Ops::Tick.call(now: task.expected_finish_at)
    assert_equal ["done", "consumed"], [task.reload.status, reservation_of(task).status]
  end

  test "재시작 후에도 LineFeed 는 예약이 남은 재고에 두 번째 feed 를 계획하지 않고, 예약은 active 로 남는다" do
    fg = Product.create!(sku: "FG-RL", name: "완제품", uom: "ea", kind: "fg")
    BomLine.create!(product: fg, component: @steel, qty_per: 1)
    machine = Machine.create!(code: "M1", name: "절단기", state: "running")
    WorkOrder.create!(code: "WO-RL", machine: machine, item: fg, product: "완제품", target_qty: 100_000, status: "active", started_at: @t0)
    stock(500) # 강판은 한 칸에 팔레트 1개뿐
    now = Time.utc(2026, 10, 8, 12, 0, 0)

    first = Simulation::LineFeed.call(now: now, logger: Logger.new(StringIO.new))
    Ops::Plan.reseed!(5) # 재시작
    again = Simulation::LineFeed.call(now: now + 10, logger: Logger.new(StringIO.new))

    assert_equal 1, first[:feed]
    assert_equal 0, again[:feed]
    assert_equal 1, Task.where(kind: "feed").count
    assert_equal ["active"], Reservation.where(product: @steel).pluck(:status)
    assert_nil available, "팔레트 1개가 전부 예약돼 있다"
  end

  test "prune 은 끝난 작업의 예약만 같이 지우고 active 예약은 남긴다" do
    stock(500)
    done = plan_feed(100)
    live = plan_feed(100)
    Ops::Tick.call(now: done.planned_at)
    Ops::Tick.call(now: done.expected_finish_at)
    assert_equal "done", done.reload.status

    deleted = Task.prune!(before: Time.current + 10.days)

    assert_equal 1, deleted
    assert_equal [live.id], Reservation.pluck(:task_id)
    assert_equal ["active"], Reservation.pluck(:status)
  end
end
