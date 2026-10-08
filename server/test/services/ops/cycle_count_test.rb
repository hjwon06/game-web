require "test_helper"
require "stringio"

# 순환 실사: 재고가 있는 칸 중 마지막 실사가 가장 오래된 칸을 골라 count 작업을 계획하고, 끝나면 차이를 adjust 이동으로 맞춘다.
class Ops::CycleCountTest < ActiveSupport::TestCase
  INTERVAL = Ops::CycleCount::INTERVAL_SECONDS
  STEP = INTERVAL + 300 # 계획 시각은 작업자 대기열 때문에 호출 시각보다 조금 늦을 수 있어 10분 간격보다 넉넉히 건너뛴다

  setup do
    Resource.ensure_defaults!
    Ops::Plan.reseed!(31)
    @now = Time.current.utc.change(usec: 0) # Plan 이 자원의 비는 시각을 실제 시계로 보므로 시험 시계도 실제 시계에서 시작한다
    @steel = Product.create!(sku: "RAW-CC", name: "실사강판", uom: "ea", kind: "raw")
    @seq = 0
  end

  def stock(code, qty, product: @steel)
    Inventory::Move.call(product: product, lot: nil, from: "supplier", to: "receiving", qty: qty, move_type: "receive",
                         ref: nil, idempotency_key: "cc-r-#{@seq += 1}")
    Inventory::Move.call(product: product, lot: nil, from: "receiving", to: code, qty: qty, move_type: "putaway",
                         ref: nil, idempotency_key: "cc-p-#{@seq += 1}")
  end

  def counted!(code, at)
    CycleCount.create!(location: Location.find_by!(code: code), product: @steel, system_qty: 1, counted_qty: 1, counted_at: at)
  end

  def run(now) = Ops::CycleCount.call(now: now, logger: Logger.new(StringIO.new))

  def counts = Task.where(kind: "count").order(:id)

  def qty_at(code) = Quant.where(product_id: @steel.id, location_id: Location.find_by!(code: code).id).sum(:qty).to_i

  def adjusts = StockMove.where(move_type: "adjust").order(:id)

  # 한 칸에 120 을 쌓고 실사 작업을 계획해 돌려준다.
  def planned_count
    stock("RAW-A-01-01", 120)
    assert_equal 1, run(@now)
    counts.sole
  end

  test "가장 오래 안 센 칸을 고른다: 한 번도 안 센 칸이 먼저, 그다음 마지막 실사가 오래된 순. 재고 없는 칸과 열린 실사 칸은 뺀다" do
    %w[RAW-A-01-01 RAW-A-01-02 RAW-A-01-03 RAW-A-01-04].each { |code| stock(code, 100) }
    # RAW-A-01-05 는 재고가 없다(후보 아님). 01 은 1시간 전, 02 는 2시간 전에 셌고 03·04 는 한 번도 안 셌다.
    counted!("RAW-A-01-01", @now - 3600)
    counted!("RAW-A-01-02", @now - 7200)

    assert_equal 1, run(@now)
    first = counts.last
    assert_equal ["RAW-A-01-03", "inventory_loss", 100, "worker", "planned"],
                 [first.from_location.code, first.to_location.code, first.qty.to_i, first.resource.kind, first.status],
                 "안 센 칸 중 코드 순 첫 칸"

    assert_equal 0, run(@now + INTERVAL - 1), "마지막 계획이 10분 안이면 아직이다"
    assert_equal 1, counts.count

    assert_equal 1, run(@now + STEP)
    assert_equal "RAW-A-01-04", counts.last.from_location.code, "03 은 실사가 열려 있어 뺀다. 남은 안 센 칸은 04"

    assert_equal 1, run(@now + (2 * STEP))
    assert_equal "RAW-A-01-02", counts.last.from_location.code, "안 센 칸이 없으면 마지막 실사가 가장 오래된 02(2시간 전)"

    assert_equal 1, run(@now + (3 * STEP))
    assert_equal "RAW-A-01-01", counts.last.from_location.code
    assert_equal 0, counts.where(from_location_id: Location.find_by!(code: "RAW-A-01-05").id).count
    assert_equal 0, adjusts.count, "계획만으로는 재고가 움직이지 않는다"
  end

  test "센 수량이 시스템 수량과 같으면 실사 기록만 남고 이동은 0이다" do
    task = planned_count

    2.times { Ops::Tick.call(now: @now + 1.day) }

    assert_equal "done", task.reload.status
    row = CycleCount.where(task_id: task.id).sole
    assert_equal [120, 120, 0], [row.system_qty.to_i, row.counted_qty.to_i, row.difference.to_i]
    assert_equal "RAW-A-01-01", row.location.code
    assert_equal 0, adjusts.count
    assert_equal 120, qty_at("RAW-A-01-01")
    assert_equal [], Inventory::Reconcile.call
  end

  test "센 수량이 모자라면 칸 -> inventory_loss adjust 이동이 생기고 Reconcile 은 0이다" do
    task = planned_count

    moves = Ops::CycleCount.complete(task, at: @now, counted: { @steel.id => 90 })

    assert_equal 1, moves.size
    move = adjusts.sole
    assert_equal ["adjust", "RAW-A-01-01", "inventory_loss", 30, task.id],
                 [move.move_type, move.from_location.code, move.to_location.code, move.qty.to_i, move.ref_id]
    assert_equal 90, qty_at("RAW-A-01-01")
    row = CycleCount.where(task_id: task.id).sole
    assert_equal [120, 90, -30], [row.system_qty.to_i, row.counted_qty.to_i, row.difference.to_i]
    assert_equal [], Inventory::Reconcile.call, "원장도 같이 움직여서 불일치가 없다"

    # 같은 작업을 같은 센 수량으로 다시 닫는다(재시도). 행도 이동도 늘지 않는다.
    Ops::CycleCount.complete(task, at: @now, counted: { @steel.id => 90 })
    assert_equal 1, CycleCount.where(task_id: task.id).count, "(작업, 품목) 행은 하나"
    assert_equal 1, adjusts.count
    assert_equal 90, qty_at("RAW-A-01-01")
  end

  test "센 수량이 남으면 inventory_loss -> 칸 adjust 이동이 생기고 Reconcile 은 0이다" do
    task = planned_count

    Ops::CycleCount.complete(task, at: @now, counted: { @steel.id => 150 })

    move = adjusts.sole
    assert_equal ["inventory_loss", "RAW-A-01-01", 30], [move.from_location.code, move.to_location.code, move.qty.to_i]
    assert_equal 150, qty_at("RAW-A-01-01")
    assert_equal 30, CycleCount.where(task_id: task.id).sole.difference.to_i
    assert_equal [], Inventory::Reconcile.call
  end
end
