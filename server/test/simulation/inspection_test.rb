require "test_helper"
require "stringio"

# 검사: qc 에 쌓인 완제품을 로트별로 묶어 팔레트(500개) 이상이거나 5분이 지나면 inspect 작업(작업자) 1건. 1건은 팔레트 1개를 넘지 않는다.
# 완료하면 불량분은 qc_fail(qc → scrap), 합격분은 지게차 적치(qc → fg 칸, 이동 유형 qc_pass).
class InspectionTest < ActiveSupport::TestCase
  include UnlimitedForkliftQueueHelper
  M0 = Time.utc(2026, 10, 8, 12, 0, 0)
  EPOCH = M0 - 3600

  setup do
    @old_epoch = ENV["INVENTORY_EPOCH"]
    ENV["INVENTORY_EPOCH"] = EPOCH.iso8601
    Resource.ensure_defaults!
    Ops::Plan.reseed!(9)
    @fg = Product.create!(sku: "FG-BR", name: "브래킷", uom: "ea", kind: "fg")
    # 적치 규칙: 완제품 창고 전체를 공용으로 연다(칸은 코드 순). 규칙 우선순위는 putaway_test 가 다룬다.
    PutawayRule.create!(product: nil, location: Location.find_by!(code: "fg_store"), priority: 50)
    @machine = Machine.create!(code: "M1", name: "절단기", state: "running")
    @order = WorkOrder.create!(code: "WO-IN1", machine: @machine, item: @fg, product: "브래킷", target_qty: 100_000,
                               status: "active", started_at: M0)
    @log = StringIO.new
  end

  teardown do
    @old_epoch.nil? ? ENV.delete("INVENTORY_EPOCH") : ENV["INVENTORY_EPOCH"] = @old_epoch
  end

  def plan(now = M0) = Simulation::Inspection.call(now: now, logger: Logger.new(@log))

  def tick = Ops::Tick.call(now: Time.current + 1.day)

  def events(good, defect)
    ProductionEvent.create!(machine: @machine, work_order: @order, bucket_start: M0 - 600, bucket_end: M0 - 590,
                            good_qty: good, defect_qty: defect, machine_version: 0)
  end

  # Logistics 가 만드는 것과 같은 모양(로트 = 작업지시 코드, 키 produce:<작업지시>:<분 ISO>)으로 qc 에 쌓는다.
  def produce_to_qc(qty, at)
    lot = Lot.find_or_create_by!(product: @fg, lot_no: @order.code)
    Inventory::Move.call(product: @fg, lot: lot, from: "production", to: "qc", qty: qty, move_type: "produce",
                         ref: @order, idempotency_key: "produce:#{@order.id}:#{at.utc.iso8601}")
    lot
  end

  def qty_at(code)
    Quant.joins(:location).where(product_id: @fg.id, locations: { code: code }).sum(:qty)
  end

  def inspects = Task.where(kind: "inspect").order(:id)

  def putaways = Task.where(kind: "putaway", from_location_id: Location.find_by!(code: "qc").id).order(:id)

  P = Simulation::Config::PALLET_QTY
  WAIT = Simulation::Config::INSPECT_MAX_WAIT_SECONDS

  test "미검사 수량이 팔레트 이상이면 바로 inspect 작업 1건이 작업자에게 계획된다" do
    lot = produce_to_qc(P, M0)

    result = plan

    assert_equal 1, result[:inspect]
    task = inspects.sole
    assert_equal ["worker", "qc", "fg_store", P, lot.id, @order.id, "WorkOrder", "planned"],
                 [task.resource.kind, task.from_location.code, task.to_location.code, task.qty.to_i, task.lot_id,
                  task.ref_id, task.ref_type, task.status]
  end

  test "팔레트 미만이고 대기가 WAIT 미만이면 inspect 를 만들지 않고, WAIT 가 되면 남은 양으로 1건 만든다" do
    produce_to_qc(P - 1, M0)

    assert_equal 0, plan(M0 + WAIT - 1)[:inspect]
    assert_equal 0, inspects.count

    assert_equal 1, plan(M0 + WAIT)[:inspect]
    assert_equal P - 1, inspects.sole.qty.to_i
  end

  test "한 inspect 수량은 팔레트를 넘지 않는다: 2.5 팔레트가 쌓이면 팔레트씩 나눠 계획한다" do
    produce_to_qc(P * 2 + P / 2, M0)

    assert_equal 1, plan(M0)[:inspect]
    assert_equal 1, plan(M0)[:inspect]
    assert_equal 0, plan(M0)[:inspect], "남은 반 팔레트는 대기 시간 전이다"
    assert_equal [P, P], inspects.map { |t| t.qty.to_i }

    assert_equal 1, plan(M0 + WAIT)[:inspect]
    assert_equal [P, P, P / 2], inspects.map { |t| t.qty.to_i }
    assert inspects.all? { |t| t.qty.to_i <= P }
  end

  test "작업지시별로 묶는다: 여러 분에 걸쳐 도착한 수량을 합쳐 1건으로 검사한다" do
    produce_to_qc(60, M0)
    produce_to_qc(70, M0 + 60)

    plan(M0 + WAIT)

    assert_equal [130], inspects.map { |t| t.qty.to_i }
  end

  test "도착 시각은 가장 오래된 미검사 도착분 기준이다: 이미 검사에 맡긴 앞 도착분은 세지 않는다" do
    produce_to_qc(P, M0)
    plan(M0)
    produce_to_qc(20, M0 + 170)

    assert_equal 0, plan(M0 + 200)[:inspect], "새 20개는 30초밖에 안 됐다"
    assert_equal 1, plan(M0 + 170 + WAIT)[:inspect]
    assert_equal [P, 20], inspects.map { |t| t.qty.to_i }
  end

  # 작업지시 하나에 로트가 여럿인 모양. lot_no 는 유일(인덱스 + 검증)해서 실제로는 한 로트뿐이지만, 계획 코드는 로트별로 도니
  # 이 테스트 트랜잭션 안에서만 유일 인덱스를 빼고(롤백된다) 같은 lot_no 의 로트를 여러 개 만든다.
  def multi_lots(count)
    Lot.connection.remove_index :lots, name: "index_lots_on_lot_no"
    Array.new(count) { Lot.new(product: @fg, lot_no: @order.code).tap { |lot| lot.save!(validate: false) } }
  end

  def produce(lot, qty, at, ref: @order)
    Inventory::Move.call(product: @fg, lot: lot, from: "production", to: "qc", qty: qty, move_type: "produce", ref: ref,
                         idempotency_key: "produce:#{@order.id}:#{lot.id}:#{at.utc.iso8601}")
  end

  test "D1: 로트가 3개인 작업지시는 로트마다 같은 미검사 수량으로 중복 계획하지 않는다 — 계획 수량 합 = 미검사 수량" do
    a, b, c = multi_lots(3)
    produce(a, 300, M0)                 # 원장상 이 작업지시의 qc 입고는 300
    produce(b, 200, M0, ref: nil)       # 로트 재고는 각각 300 / 200 / 200 이지만
    produce(c, 200, M0, ref: nil)       # 작업지시 미검사 수량은 300 뿐이다

    result = plan(M0 + WAIT)

    assert_equal 300, inspects.sum(:qty).to_i, "로트마다 min(300, 재고)로 잡으면 700 이 된다"
    assert_equal [a.id], inspects.map(&:lot_id), "앞 로트가 미검사를 다 가져가 나머지 로트는 계획하지 않는다"
    assert_equal 1, result[:inspect]
    assert_equal 0, plan[:inspect], "다시 불러도 늘지 않는다"
  end

  test "D1: 미검사 수량이 로트에 나뉘어 있으면 로트 몫만큼씩 계획하고 합은 미검사 수량이다" do
    a, b, c = multi_lots(3)
    [a, b, c].each_with_index { |lot, i| produce(lot, 40, M0 + (i * 60)) }

    plan(M0 + WAIT + 300) # 세 로트 모두 대기 상한(WAIT)을 넘긴 시각

    assert_equal [40, 40, 40], inspects.map { |t| t.qty.to_i }
    assert_equal [a.id, b.id, c.id], inspects.map(&:lot_id)
    assert_equal 120, inspects.sum(:qty).to_i
  end

  test "D3: 로트가 여럿이어도 도착 시각 조회는 쿼리 1회다(로트마다 조회하지 않는다)" do
    a, b, c = multi_lots(3)
    [a, b, c].each_with_index { |lot, i| produce(lot, 40, M0 + (i * 60)) }
    arrival_queries = []
    counter = ->(*, payload) { arrival_queries << payload[:sql] if payload[:sql].include?("substring(idempotency_key from") }

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { plan(M0 + WAIT + 300) }

    assert_equal 3, inspects.count, "세 로트 모두 대기 상한(WAIT)을 넘겨 검사가 계획됐다"
    # 도착 시각식(ARRIVED_AT_SQL)을 쓰는 쿼리: 로트별 도착 조회 1회 + 작업지시별 미검사량(EPOCH 필터, ⑥d) 1회. 로트 수와 무관하게 2회다
    assert_equal 2, arrival_queries.size
  end

  test "D3: 로트별 도착 시각이 따로 계산된다 — 대기 상한이 안 된 로트는 건너뛰고 지난 로트만 검사한다" do
    a, b = multi_lots(2)
    produce(a, 30, M0)
    produce(b, 30, M0 + WAIT - 50)

    plan(M0 + WAIT + 10)

    assert_equal [a.id], inspects.map(&:lot_id), "b 는 60초밖에 안 됐다"
  end

  test "같은 시각에 다시 불러도 작업·이동이 늘지 않는다" do
    produce_to_qc(100, M0 - WAIT)
    plan
    tick
    plan
    tasks = Task.count
    moves = StockMove.count

    again = plan

    assert_equal [0, 0], [again[:inspect], again[:putaway]]
    assert_equal tasks, Task.count
    assert_equal moves, StockMove.count
  end

  test "완료하면 불량분은 qc_fail(qc → scrap)이고 합격분은 지게차 적치로 fg 칸에 qc_pass 로 들어간다" do
    events(90, 10) # 불량률 10%
    produce_to_qc(100, M0 - WAIT)
    plan

    base = StockMove.count
    tick
    task = inspects.sole.reload
    assert_equal "done", task.status
    assert_equal base + 1, StockMove.count, "검사 완료 이동은 qc_fail 1건뿐이다"
    assert_equal ["qc_fail", "qc_fail:task:#{task.id}", 10], [task.stock_move.move_type, task.stock_move.idempotency_key, task.stock_move.qty.to_i]
    assert_equal [90, 10], [qty_at("qc"), qty_at("scrap")]

    put = putaways.sole # 검사 완료와 같은 트랜잭션에서 이미 계획됐다
    assert_equal 0, plan[:putaway], "주기 계획은 같은 적치를 또 만들지 않는다"
    assert_equal ["forklift", "FG-A-01-01", 90, "Task", task.id, task.lot_id],
                 [put.resource.kind, put.to_location.code, put.qty.to_i, put.ref_type, put.ref_id, put.lot_id]

    tick
    assert_equal "done", put.reload.status
    assert_equal "qc_pass", put.stock_move.move_type
    assert_equal ["qc", "FG-A-01-01"], [put.stock_move.from_location.code, put.stock_move.to_location.code]
    assert_equal [0, 90, 10], [qty_at("qc"), qty_at("FG-A-01-01"), qty_at("scrap")]
    assert_equal %w[fail pass], Inspection.where(lot_id: task.lot_id).order(:result).pluck(:result)
    assert_equal [10, 0], Inspection.where(lot_id: task.lot_id).order(:result).pluck(:defect_qty).map(&:to_i)
    assert_equal [], Inventory::Reconcile.call
  end

  test "6d: 생산 N 이면 검사 수량 합은 N 이고 EPOCH 이전 생산은 검사하지 않으며, 검사가 끝난 재고를 다시 검사하지 않는다" do
    events(100, 0)
    produce_to_qc(700, EPOCH - 60) # rebase 이전 생산: 소급하지 않는다
    produce_to_qc(3 * P, M0 - WAIT)
    plan
    10.times do
      tick
      plan
    end

    assert_equal 3 * P, inspects.where(status: "done").sum(:qty).to_i, "검사 수량 합 = EPOCH 이후 생산"
    assert_equal [P, P, P], inspects.map { |t| t.qty.to_i }
    assert_equal 0, plan[:inspect], "qc 에 EPOCH 이전 700 이 남아 있어도 더 검사하지 않는다"
  end

  test "6d: 검사 완료 직후 합격분 적치가 같은 틱에 계획되고 가용 부족 로그가 없다" do
    events(90, 10)
    produce_to_qc(100, M0 - WAIT)
    plan
    produce_to_qc(40, M0 - 10) # 검사 중에 더 쌓인 양: 검사 대기 중인 다음 몫과 겹쳐도 합격분 예약은 성공해야 한다

    tick

    task = inspects.first.reload
    assert_equal "done", task.status
    put = putaways.sole
    assert_equal [90, "planned", task.id], [put.qty.to_i, put.status, put.ref_id]
    assert_equal "active", put.reservation.status
    assert_no_match(/가용 부족/, @log.string)
  end

  test "불량률 0 이면 qc_fail 없이 검사가 끝나고 전량 적치된다" do
    events(100, 0)
    produce_to_qc(50, M0 - WAIT)
    plan
    base = StockMove.count

    tick

    task = inspects.sole.reload
    assert_equal "done", task.status
    assert_nil task.stock_move
    assert_equal base, StockMove.count
    plan
    assert_equal [50], putaways.map { |t| t.qty.to_i }
  end

  test "불량 수량은 EPOCH 이후 불량률 x 검사 수량을 반올림한다(EPOCH 이전 생산은 무시)" do
    events(90, 10)
    ProductionEvent.create!(machine: @machine, work_order: @order, bucket_start: EPOCH - 100, bucket_end: EPOCH - 90,
                            good_qty: 0, defect_qty: 5_000, machine_version: 0)
    produce_to_qc(125, M0 - WAIT)
    plan
    tick

    assert_equal 13, StockMove.where(move_type: "qc_fail").sum(:qty) # 12.5 → 13
    plan
    assert_equal [112], putaways.map { |t| t.qty.to_i }
  end

  test "합격분 칸 고르기: 같은 품목이 있는 칸 → 빈 칸 코드 순. 다른 품목이 점유한 칸은 건너뛴다" do
    other = Product.create!(sku: "FG-OT", name: "다른 완제품", uom: "ea", kind: "fg")
    Inventory::Move.call(product: other, lot: nil, from: "production", to: "qc", qty: 10, move_type: "produce", ref: nil,
                         idempotency_key: "ins-other-prod")
    Inventory::Move.call(product: other, lot: nil, from: "qc", to: "FG-A-01-01", qty: 10, move_type: "qc_pass", ref: nil,
                         idempotency_key: "ins-other-pass")
    events(100, 0)
    produce_to_qc(100, M0 - WAIT)
    plan
    tick
    plan
    assert_equal ["FG-A-01-02"], putaways.map { |t| t.to_location.code }, "01 칸은 다른 품목이 있어 다음 빈 칸"
    tick

    produce_to_qc(100, M0 - WAIT + 60) # plan(M0 + 60) 시점에 대기 상한(WAIT)에 닿는다
    plan(M0 + 60)
    tick
    plan(M0 + 60)
    assert_equal ["FG-A-01-02", "FG-A-01-02"], putaways.map { |t| t.to_location.code }, "같은 품목이 있는 칸에 남은 용량이 있으면 거기로"
  end

  test "합격 적치가 취소돼 qc 에 남은 수량은 다시 검사하지 않고 적치만 다시 계획한다(3번까지)" do
    events(100, 0)
    produce_to_qc(100, M0 - WAIT)
    plan
    tick
    plan
    putaways.sole.update!(status: "cancelled", cancel_reason: "test")

    again = plan

    assert_equal [0, 1], [again[:inspect], again[:putaway]], "qc 재고가 남아 있어도 검사는 한 번만"
    assert_equal 1, inspects.count
    assert_equal 2, putaways.count

    # update_all 은 Task 콜백(예약 해제)을 건너뛴다. 실제 취소 경로(Ops::Tick)처럼 모델로 취소해야 qc 재고를 잡은 예약이 풀린다.
    putaways.where(status: "planned").each { |t| t.update!(status: "cancelled", cancel_reason: "test") }
    plan
    putaways.where(status: "planned").each { |t| t.update!(status: "cancelled", cancel_reason: "test") }
    assert_equal 0, plan[:putaway], "취소가 3번이면 더 계획하지 않는다"
    assert_equal 3, putaways.count
  end

  test "적치 규칙이 없으면 합격분은 칸을 못 받아 qc 에 남고 waiting 으로 센다" do
    PutawayRule.delete_all
    events(100, 0)
    produce_to_qc(100, M0 - WAIT)
    plan
    tick

    result = plan

    assert_equal [0, 1], [result[:putaway], result[:waiting]]
    assert_equal 0, putaways.count
    assert_equal 100, qty_at("qc")
  end

  # 6e: 반복 검사 버그 시절에 남은 모양 — 끝난 검사(합격분 전량)의 수량 합이 qc 실재고보다 크다. qc 재고는 EPOCH 이전 도착이라 새로 검사하지 않는다.
  def stale_inspect(qty, finished_at, lot)
    Task.create!(kind: "inspect", status: "done", resource: Resource.find_by!(kind: "worker"), product: @fg, lot: lot, qty: qty,
                 from_location: Location.find_by!(code: "qc"), to_location: Location.find_by!(code: "fg_store"),
                 planned_at: finished_at - 60, started_at: finished_at - 60, finished_at: finished_at,
                 ref_type: "WorkOrder", ref_id: @order.id)
  end

  def live_putaway_qtys = putaways.where.not(status: "cancelled").map { |t| t.qty.to_i }

  # minitest 6 에는 Object#stub 이 없다(minitest/mock 분리). Ops::Plan.call 호출을 센다 — 0 이어야 한다.
  module PlanCallCounter
    def call(**kw)
      PlanCallCounter.calls += 1 if PlanCallCounter.armed
      super
    end
    class << self
      attr_accessor :calls, :armed
    end
  end
  Ops::Plan.singleton_class.prepend(PlanCallCounter)

  def plan_without_plan_calls
    PlanCallCounter.calls = 0
    PlanCallCounter.armed = true
    result = plan
    assert_equal 0, PlanCallCounter.calls, "Ops::Plan 을 부르면 안 된다"
    result
  ensure
    PlanCallCounter.armed = false
  end

  test "6e: 검사 기록 합 > qc 실재고면 오래된 검사부터 실재고만큼만 적치하고, 나머지는 Plan 호출·예외 없이 종결해 다시 보지 않는다" do
    lot = produce_to_qc(100, EPOCH - 60)
    [M0 - 300, M0 - 200, M0 - 100].each { |at| stale_inspect(60, at, lot) } # 합 180 > 실재고 100

    result = plan

    assert_equal 2, result[:putaway]
    assert_equal [60, 40], live_putaway_qtys, "오래된 검사부터 min(합격분, 남은 가용)"
    assert_equal 100, live_putaway_qtys.sum
    assert_equal 1, putaways.where(status: "cancelled", cancel_reason: Simulation::Inspection::SETTLED_REASON).count
    assert_no_match(/InsufficientStock/, @log.string)

    tasks = Task.count
    again = plan_without_plan_calls
    assert_equal [0, 0], [again[:putaway], again[:waiting]], "다음 호출에 재시도하지 않는다"
    assert_equal tasks, Task.count
  end

  test "6e: qc 가용이 이미 0 이면 모든 대기 검사를 Plan 호출 없이 종결하고 다음 호출에 다시 보지 않는다" do
    lot = Lot.find_or_create_by!(product: @fg, lot_no: @order.code)
    3.times { |i| stale_inspect(50, M0 - 300 + i, lot) }

    plan_without_plan_calls
    assert_equal 3, putaways.where(cancel_reason: Simulation::Inspection::SETTLED_REASON).count
    assert_equal [], live_putaway_qtys

    tasks = Task.count
    plan_without_plan_calls
    assert_equal tasks, Task.count
  end

  test "6e: 가용은 active 예약을 뺀 값이다 — 다른 작업이 잡은 qc 재고는 적치하지 않는다" do
    lot = produce_to_qc(100, EPOCH - 60)
    stale_inspect(100, M0 - 100, lot)
    Ops::Plan.call(kind: "inspect", product: @fg, lot: lot, qty: 70, from: "qc", to: "fg_store", ref: @order, earliest_at: M0)

    plan

    assert_equal [30], live_putaway_qtys, "실재고 100 - 예약 70"
  end

  test "6e: 기록 = 실재고인 정상 경우는 합격분 전량을 적치하고 종결 표시를 만들지 않는다" do
    lot = produce_to_qc(100, EPOCH - 60)
    stale_inspect(60, M0 - 200, lot)
    stale_inspect(40, M0 - 100, lot)

    assert_equal 2, plan[:putaway]

    assert_equal [60, 40], live_putaway_qtys
    assert_equal 0, putaways.where(status: "cancelled").count
    assert_equal 0, plan[:putaway]
  end

  test "6e: 경고 로그는 호출당 1줄이다(건수 합계)" do
    PutawayRule.delete_all
    lot = produce_to_qc(100, EPOCH - 60)
    5.times { |i| stale_inspect(10, M0 - 300 + i, lot) }

    plan

    assert_equal 1, @log.string.lines.grep(/WARN/).size
    assert_match(/5건/, @log.string)

    @log.truncate(0)
    @log.rewind
    plan
    assert_equal 1, @log.string.lines.grep(/WARN/).size, "칸이 없어 대기 중이면 매 호출 1줄"
  end

  test "6e: 즉시 적치(plan_putaway_for)도 같은 가용 상한을 쓴다" do
    lot = produce_to_qc(30, EPOCH - 60)
    task = stale_inspect(100, M0 - 100, lot)

    put = Simulation::Inspection.plan_putaway_for(task, now: M0, logger: Logger.new(@log))

    assert_equal 30, put.qty.to_i
    assert_nil Simulation::Inspection.plan_putaway_for(task, now: M0, logger: Logger.new(@log)), "가용 0 이면 Plan 을 부르지 않고 nil"
  end

  test "작업지시 코드와 맞지 않는 로트나 다른 위치의 재고는 검사하지 않는다" do
    lot = Lot.create!(product: @fg, lot_no: "LOT-SEED-1")
    Inventory::Move.call(product: @fg, lot: lot, from: "production", to: "qc", qty: 500, move_type: "produce", ref: nil,
                         idempotency_key: "ins-seed-prod")

    assert_equal 0, plan[:inspect]
    assert_equal 0, Task.count
  end

  test "한 단계가 실패해도 다른 단계는 계속되고 실패는 로그에 남는다" do
    produce_to_qc(100, M0 - WAIT)
    original = Simulation::Inspection.instance_method(:plan_inspections)
    Simulation::Inspection.send(:define_method, :plan_inspections) { raise "검사 계획 실패" }
    begin
      result = plan
    ensure
      Simulation::Inspection.send(:define_method, :plan_inspections, original)
    end

    assert_equal 0, result[:inspect]
    assert_equal 1, @log.string.lines.grep(/sim inspection inspect .*검사 계획 실패/).size
  end
end
