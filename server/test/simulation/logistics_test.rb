require "test_helper"
require "stringio"

# 생산 → 자재 소비(백플러시). 자재는 line_side 에서만 나간다. 입고는 inbound_test.rb, 라인 공급은 line_feed_test.rb 에서 본다.
class LogisticsTest < ActiveSupport::TestCase
  include UnscaledRatesHelper
  M0 = Time.utc(2026, 10, 8, 12, 0, 0)
  EPOCH = M0 - 3600
  BIN1 = "RAW-A-01-01".freeze

  setup do
    @old_epoch = ENV["INVENTORY_EPOCH"]
    ENV["INVENTORY_EPOCH"] = EPOCH.iso8601
    @steel = Product.create!(sku: "RAW-S", name: "강판", uom: "ea", kind: "raw")
    @bolt = Product.create!(sku: "RAW-B", name: "볼트", uom: "ea", kind: "raw")
    @fg = Product.create!(sku: "FG-BR", name: "브래킷", uom: "ea", kind: "fg")
    BomLine.create!(product: @fg, component: @steel, qty_per: 2)
    BomLine.create!(product: @fg, component: @bolt, qty_per: 1)
    @machine = Machine.create!(code: "M1", name: "절단기", state: "running") # 0.8/s, 불량 2% → 양품 0.784/s
    @order = WorkOrder.create!(code: "WO-L1", machine: @machine, item: @fg, product: "브래킷", target_qty: 100_000,
                               status: "active", started_at: M0)
    @log = StringIO.new
    @line_side = Location.find_by!(code: "line_side")
    # 용량은 line_feed_test·move_capacity_test 에서 본다
    Location.where(id: Simulation::Inbound.bins_under("raw_store").select(:id)).update_all(capacity_units: 1_000_000)
    Location.where(id: @line_side.id).update_all(capacity_units: 1_000_000)
    Simulation::Logistics.reset_state!
  end

  teardown do
    Simulation::Logistics.reset_state!
    @old_epoch.nil? ? ENV.delete("INVENTORY_EPOCH") : ENV["INVENTORY_EPOCH"] = @old_epoch
  end

  # 공급처 → 입고대 → raw 칸 → (line: true 면) line_side. Ops 를 거치지 않고 재고만 만든다(소비 쪽만 보려는 테스트용).
  def stock(product, qty, bin: BIN1, lot: nil, line: true)
    tag = "#{product.id}-#{qty}-#{bin}-#{lot&.id}"
    Inventory::Move.call(product: product, lot: lot, from: "supplier", to: "receiving", qty: qty, move_type: "receive",
                         ref: nil, idempotency_key: "test-recv-#{tag}")
    Inventory::Move.call(product: product, lot: lot, from: "receiving", to: bin, qty: qty, move_type: "putaway",
                         ref: nil, idempotency_key: "test-put-#{tag}")
    return unless line

    Inventory::Move.call(product: product, lot: lot, from: bin, to: "line_side", qty: qty, move_type: "feed",
                         ref: nil, idempotency_key: "test-feed-#{tag}")
  end

  def event(at, good, order: @order)
    ProductionEvent.create!(machine: order.machine, work_order: order, bucket_start: at, bucket_end: at + 10,
                            good_qty: good, defect_qty: 0, machine_version: 0)
  end

  def run_minute(n)
    Simulation::Logistics.call(now: M0 + (n * 60), logger: Logger.new(@log))
  end

  def qty_at(product, code)
    Quant.joins(:location).where(product_id: product.id, locations: { code: code }).sum(:qty)
  end

  def moves(type) = StockMove.where(move_type: type)

  test "EPOCH 이전 생산은 소비하지 않는다" do
    stock(@steel, 1000)
    stock(@bolt, 1000)
    event(EPOCH - 10, 50) # 이전
    event(EPOCH, 20)      # 경계 포함
    event(M0 - 20, 5)

    run_minute(0)

    assert_equal 25, moves("produce").sum(:qty)
    assert_equal 950, qty_at(@steel, "line_side")
    assert_equal 975, qty_at(@bolt, "line_side")
  end

  test "EPOCH 이후 생산이 없으면 아무것도 소비하지 않는다" do
    stock(@steel, 1000)
    stock(@bolt, 1000)
    event(EPOCH - 10, 500)

    run_minute(0)

    assert_equal 0, moves("produce").count
    assert_equal 0, moves("issue").count
  end

  test "ENV 가 없으면 locations 첫 생성 시각이 기준이다" do
    ENV.delete("INVENTORY_EPOCH")
    assert_equal Location.minimum(:created_at), Simulation::Config.inventory_epoch
    ENV["INVENTORY_EPOCH"] = "2026-10-08T00:00:00Z"
    assert_equal Time.utc(2026, 10, 8), Simulation::Config.inventory_epoch
  end

  test "Logistics 는 입고·검사·출하를 하지 않는다: 결과 키는 backflush·skipped·order 뿐이고 재고가 0 이어도 이동을 만들지 않는다" do
    result = run_minute(0)

    assert_equal %i[backflush skipped order], result.keys
    %w[receive putaway feed pick qc_pass qc_fail ship].each { |type| assert_equal 0, moves(type).count, type }
  end

  test "같은 분을 두 번 실행해도 이동이 늘지 않는다" do
    stock(@steel, 1000)
    stock(@bolt, 1000)
    event(M0 - 20, 30)

    first = run_minute(0)
    before = StockMove.count
    again = run_minute(0)

    assert_equal 1, first[:backflush]
    assert_equal 3, moves("issue").count + moves("produce").count, "issue 2(강판·볼트) + produce 1"
    assert_equal before, StockMove.count
    assert_equal 0, again[:backflush]
  end

  test "같은 분 재실행 사이에 생산이 늘어도 예외 없이 이동이 늘지 않고, 남은 수량은 다음 분에 처리된다" do
    stock(@steel, 10_000)
    stock(@bolt, 10_000)
    event(M0 - 20, 30)
    run_minute(0)
    assert_equal [30], moves("produce").pluck(:qty).map(&:to_i)

    event(M0 - 10, 10) # 같은 분 안에 생산이 늘었다
    before = StockMove.count
    again = run_minute(0)

    assert_equal [], @log.string.lines.grep(/ERROR|IdempotencyConflict/)
    assert_equal before, StockMove.count
    assert_equal 0, again[:backflush]

    assert_equal 1, run_minute(1)[:backflush]
    assert_equal [30, 10], moves("produce").order(:id).pluck(:qty).map(&:to_i)
    assert_equal 0, @log.string.lines.grep(/IdempotencyConflict/).size
  end

  test "다음 분에는 새로 생긴 생산분만 소비한다" do
    stock(@steel, 1000)
    stock(@bolt, 1000)
    event(M0 - 20, 30)
    run_minute(0)
    event(M0 + 40, 10)
    run_minute(1)

    assert_equal [30, 10], moves("produce").order(:id).pluck(:qty).map(&:to_i)
  end

  test "자재 하나가 line_side 에 0 이면 그 분은 건너뛰고(이동 0), 공급되면 다음 분에 소비를 재개한다" do
    stock(@bolt, 10_000) # 강판은 line_side 에 없다
    event(M0 - 20, 100)

    a = run_minute(0)
    assert_equal [0, 1], [a[:backflush], a[:skipped]]
    assert_equal 0, moves("produce").count
    assert_equal 0, moves("issue").count, "볼트는 충분했지만 아무것도 빠지지 않는다"
    assert_equal 0, qty_at(@steel, "line_side")
    assert_equal 0, moves("receive").where("idempotency_key LIKE 'sim:%'").count, "Logistics 는 트럭을 부르지 않는다"

    stock(@steel, 500, bin: "RAW-A-01-02") # feed 완료 = line_side 에 들어옴
    b = run_minute(1)
    assert_equal [1, 0], [b[:backflush], b[:skipped]]
    assert_equal 100, moves("produce").sum(:qty)
    assert_equal 300, qty_at(@steel, "line_side")
    assert_equal 0, Quant.joins(:location).where(locations: { kind: "physical" }).where("quants.qty < 0").count
    assert_equal [], Inventory::Reconcile.call
  end

  test "raw 칸에만 있는 재고는 쓰지 않는다: line_side 가 비어 있으면 건너뛴다" do
    stock(@steel, 1000, line: false)
    stock(@bolt, 1000, line: false)
    event(M0 - 20, 30)

    result = run_minute(0)

    assert_equal [0, 1], [result[:backflush], result[:skipped]]
    assert_equal 0, moves("issue").count
    assert_equal 1000, qty_at(@steel, "RAW-A-01-01"), "raw 칸 재고는 그대로다"
  end

  test "로트가 여럿이면 로트 없는 재고 → 오래된 로트 순으로 빼고, 한 로트가 모자라면 다음 로트에서 이어 뺀다" do
    lot_a = Lot.create!(product: @steel, lot_no: "R-T-A", created_at: M0 - 7200, updated_at: M0 - 7200)
    lot_b = Lot.create!(product: @steel, lot_no: "R-T-B", created_at: M0 - 3600, updated_at: M0 - 3600)
    stock(@steel, 150, bin: "RAW-A-01-02", lot: lot_b) # 늦은 로트를 먼저 공급해도
    stock(@steel, 100, bin: BIN1, lot: lot_a)          # 오래된 로트부터 빠진다
    stock(@bolt, 500)
    event(M0 - 20, 100) # 강판 200, 볼트 100

    run_minute(0)

    steel_issues = moves("issue").where(product_id: @steel.id).order(:id).to_a
    assert_equal %w[line_side line_side], steel_issues.map { |m| m.from_location.code }
    assert_equal [100, 100], steel_issues.map { |m| m.qty.to_i }
    assert_equal [lot_a.id, lot_b.id], steel_issues.map(&:lot_id), "빼는 이동이 line_side 재고의 로트를 그대로 따른다"
    assert_equal 50, qty_at(@steel, "line_side")
    assert_equal 400, qty_at(@bolt, "line_side")
    assert_equal [], Inventory::Reconcile.call
  end

  test "백플러시 분할: pending 5,000 에 자재가 일부뿐이면 자재가 허용하는 만큼(상한 300)만 소비하고 다음 분에 이어서 소비한다" do
    stock(@steel, 1000) # 강판 2개당 1개 → 500개분
    stock(@bolt, 10_000)
    event(M0 - 20, 5000)

    assert_equal [1, 0], run_minute(0).values_at(:backflush, :skipped)
    assert_equal [300], moves("produce").pluck(:qty).map(&:to_i), "min(5000, 500, 300)"
    assert_equal 400, qty_at(@steel, "line_side")

    assert_equal 1, run_minute(1)[:backflush]
    assert_equal [300, 200], moves("produce").order(:id).pluck(:qty).map(&:to_i), "강판 400 → 200개분이 상한보다 작다"
    assert_equal 0, qty_at(@steel, "line_side")

    assert_equal [0, 1], run_minute(2).values_at(:backflush, :skipped)
    assert_equal 500, moves("produce").sum(:qty)

    stock(@steel, 2000, bin: "RAW-A-01-02")
    assert_equal 1, run_minute(3)[:backflush]
    # pending 은 BACKLOG_CAP(= 상한 300 x 2 = 600) 에서 잘렸으므로 남은 100 만 이어서 소비한다(⑥c)
    assert_equal Simulation::Config::BACKLOG_CAP, moves("produce").sum(:qty), "공급되자 남은 pending 만큼 이어서 소비"
    assert_equal [], Inventory::Reconcile.call
  end

  test "자재 하나가 0 이면 그 작업지시만 0 이고 다른 작업지시는 진행한다" do
    nut = Product.create!(sku: "RAW-N", name: "너트", uom: "ea", kind: "raw")
    fg2 = Product.create!(sku: "FG-NT", name: "너트세트", uom: "ea", kind: "fg")
    BomLine.create!(product: fg2, component: nut, qty_per: 1)
    machine2 = Machine.create!(code: "M2", name: "프레스", state: "running")
    order2 = WorkOrder.create!(code: "WO-L2", machine: machine2, item: fg2, product: "너트세트", target_qty: 100_000,
                               status: "active", started_at: M0)
    stock(@bolt, 1000) # 강판 0 → 첫 작업지시는 못 만든다
    stock(nut, 1000)
    event(M0 - 20, 100)
    event(M0 - 20, 100, order: order2)

    result = run_minute(0)

    assert_equal [1, 1], result.values_at(:backflush, :skipped)
    assert_equal [order2.id], moves("produce").pluck(:ref_id)
    assert_equal 900, qty_at(nut, "line_side")
    assert_equal 1000, qty_at(@bolt, "line_side"), "첫 작업지시는 볼트도 쓰지 않는다"
  end

  test "BACKLOG_CAP 을 넘는 pending 은 소급하지 않고 버리며 로그 1줄을 남긴다" do
    stock(@steel, 100_000)
    stock(@bolt, 100_000)
    event(M0 - 20, 8000)

    run_minute(0)
    18.times { |n| run_minute(n + 1) }

    assert_equal 600, Simulation::Config::BACKLOG_CAP
    assert_equal 600, moves("produce").sum(:qty), "8000 중 7400 은 버려 BACKLOG_CAP(600)만 소비한다"
    assert_equal 1, @log.string.lines.grep(/7400개를 소급하지 않고 버림/).size
    assert_equal 0, run_minute(19)[:backflush], "다 소비한 뒤에는 따라잡을 것이 없다"
  end

  test "작업지시가 10분 연속 자재 부족이면 부족한 자재를 로그 1줄로 남기고, 같은 분 재호출은 세지 않는다" do
    stock(@bolt, 1000)
    event(M0 - 20, 100)

    9.times { |n| run_minute(n) }
    run_minute(8) # 같은 분 재호출
    assert_empty @log.string.lines.grep(/자재 부족 연속/)

    run_minute(9)
    lines = @log.string.lines.grep(/자재 부족 연속/)
    assert_equal 1, lines.size
    assert_match(/WO-L1 자재 부족 연속 10분: RAW-S line_side 0\.0 /, lines.first)

    stock(@steel, 1000)
    run_minute(10)
    assert_equal 0, Simulation::Logistics.state[:starved].size, "소비가 재개되면 연속 분 수가 지워진다"
  end

  # M1 은 초당 0.8개 → 다음 60초 48개. 강판 2개·볼트 1개씩이라 강판 96, 볼트 48 이 필요하다.
  test "line_side 가 다음 60초 생산분을 못 대면 material_short_since 를 분 시각으로 채우고, 이미 있으면 유지하며, 기계 state·version 은 그대로다" do
    stock(@steel, 95) # 96 필요
    stock(@bolt, 1000)
    version = @machine.version

    run_minute(0)
    assert_equal M0, @machine.reload.material_short_since
    assert_equal ["running", version], [@machine.state, @machine.version]
    assert_equal 1, @log.string.lines.grep(/M1 자재 대기 시작: RAW-S line_side 95\.0 \/ 다음 60초 필요 96\.0/).size

    run_minute(1)
    assert_equal M0, @machine.reload.material_short_since, "이미 있으면 처음 시각을 유지한다"
    assert_equal 1, @log.string.lines.grep(/자재 대기 시작/).size, "바뀔 때만 로그를 남긴다"
  end

  test "라인사이드가 보충되면 material_short_since 가 nil 이 되고 로그 1줄을 남긴다" do
    stock(@bolt, 1000)
    run_minute(0)
    assert_not_nil @machine.reload.material_short_since

    stock(@steel, 96)
    run_minute(3)

    assert_nil @machine.reload.material_short_since
    assert_equal 1, @log.string.lines.grep(/M1 자재 대기 해제 \(3분\)/).size
  end

  test "정확히 필요량이면 자재 대기가 아니다. running 이 아닌 기계의 표시는 지운다" do
    stock(@steel, 96)
    stock(@bolt, 48)
    run_minute(0)
    assert_nil @machine.reload.material_short_since

    @machine.update_columns(material_short_since: M0 - 600, state: "stopped")
    run_minute(1)
    assert_nil @machine.reload.material_short_since
  end

  test "자재 대기 기계에는 생산을 쌓지 않는 snapshot 을 넘긴다: 자재가 오면 재개한다" do
    runner = Simulation::Runner.new(logger: Logger.new(@log))
    @machine.update_columns(material_short_since: M0)

    snapshot = runner.send(:snapshot)
    assert_equal [{ code: "M1", state: "waiting_material", version: 0 }], snapshot

    accumulator = Simulation::Accumulator.new
    rng = Random.new(1)
    60.times { accumulator.tick(snapshot, rng) }
    assert_equal 0, accumulator.entry("M1").good_qty

    @machine.update_columns(material_short_since: nil)
    snapshot = runner.send(:snapshot)
    assert_equal "running", snapshot.first[:state]
    60.times { accumulator.tick(snapshot, rng) }
    assert_operator accumulator.entry("M1").good_qty, :>, 0
  end

  test "epoch 는 ENV > 최신 sim_epochs > locations 첫 생성 순이다" do
    ENV.delete("INVENTORY_EPOCH")
    assert_equal Location.minimum(:created_at), Simulation::Config.inventory_epoch

    SimEpoch.create!(started_at: M0 - 600)
    SimEpoch.create!(started_at: M0)
    assert_equal M0, Simulation::Config.inventory_epoch, "가장 늦은 started_at"

    ENV["INVENTORY_EPOCH"] = (M0 + 5).iso8601
    assert_equal M0 + 5, Simulation::Config.inventory_epoch
  end

  test "rebase 뒤에는 epoch 이후의 생산·소비만 센다: 이전 produce 이동이 pending 을 음수로 만들지 않는다" do
    stock(@steel, 10_000)
    stock(@bolt, 10_000)
    event(M0 - 20, 100)
    run_minute(0)
    assert_equal [100], moves("produce").pluck(:qty).map(&:to_i)

    ENV.delete("INVENTORY_EPOCH")
    SimEpoch.create!(started_at: M0 + 30)
    event(M0 + 40, 30)
    run_minute(1)

    assert_equal [100, 30], moves("produce").order(:id).pluck(:qty).map(&:to_i), "done 이 100 으로 잡혔다면 pending 이 음수라 30 이 소비되지 않는다"
  end

  test "rebase 직후 밀린 생산(pending)은 0 이다: 이전 생산은 소비하지도 상한 로그를 남기지도 않는다" do
    stock(@steel, 100_000)
    stock(@bolt, 100_000)
    event(M0 - 20, 8000)
    ENV.delete("INVENTORY_EPOCH")
    SimEpoch.create!(started_at: M0 - 10)

    result = run_minute(0)

    assert_equal 0, result[:backflush]
    assert_equal 0, moves("produce").count
    assert_empty @log.string.lines.grep(/미소비/)
  end

  test "issue 멱등키는 issue:<작업지시>:<자재>:<line_side>:<로트>:<분 ISO> 이다" do
    stock(@steel, 1000)
    stock(@bolt, 1000)
    event(M0 - 20, 10)
    run_minute(0)

    assert_equal ["issue:#{@order.id}:#{@steel.id}:#{@line_side.id}:0:2026-10-08T12:00:00Z"],
                 moves("issue").where(product_id: @steel.id).pluck(:idempotency_key)
  end
end
