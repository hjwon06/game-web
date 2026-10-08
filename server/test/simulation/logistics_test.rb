require "test_helper"
require "stringio"

# 생산 → 자재 소비(백플러시). 입고(트럭·하차·적치)는 inbound_test.rb 에서 본다.
class LogisticsTest < ActiveSupport::TestCase
  M0 = Time.utc(2026, 10, 8, 12, 0, 0)
  EPOCH = M0 - 3600
  BIN1 = "RAW-A-01-01".freeze
  BIN2 = "RAW-A-01-02".freeze

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
    Location.where(id: Simulation::Inbound.bins_under("raw_store").select(:id)).update_all(capacity_units: 1_000_000) # 용량은 inbound_test 에서 본다
  end

  teardown do
    @old_epoch.nil? ? ENV.delete("INVENTORY_EPOCH") : ENV["INVENTORY_EPOCH"] = @old_epoch
  end

  # 공급처 → 입고대 → 칸. Ops 를 거치지 않고 재고만 만든다(소비 쪽만 보려는 테스트용).
  def stock(product, qty, bin: BIN1, lot: nil)
    tag = "#{product.id}-#{qty}-#{bin}-#{lot&.id}"
    Inventory::Move.call(product: product, lot: lot, from: "supplier", to: "receiving", qty: qty, move_type: "receive",
                         ref: nil, idempotency_key: "test-recv-#{tag}")
    Inventory::Move.call(product: product, lot: lot, from: "receiving", to: bin, qty: qty, move_type: "putaway",
                         ref: nil, idempotency_key: "test-put-#{tag}")
  end

  def event(at, good)
    ProductionEvent.create!(machine: @machine, work_order: @order, bucket_start: at, bucket_end: at + 10,
                            good_qty: good, defect_qty: 0, machine_version: 0)
  end

  def run_minute(n)
    Simulation::Logistics.call(now: M0 + (n * 60), logger: Logger.new(@log))
  end

  # product 의 raw_store 하위 칸(+ raw_store 자체) 재고 합.
  def store_qty(product)
    ids = Location.where(code: "raw_store").pluck(:id) + Simulation::Inbound.bins_under("raw_store").pluck(:id)
    Quant.where(product_id: product.id, location_id: ids).sum(:qty)
  end

  def bin_qty(product, code)
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
    assert_equal 950, store_qty(@steel)
    assert_equal 975, store_qty(@bolt)
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

  test "Logistics 는 입고를 하지 않는다: 결과 키에 receive·putaway 가 없고 재고가 0 이어도 이동을 만들지 않는다" do
    result = run_minute(0)

    assert_equal %i[backflush skipped inspect ship order], result.keys
    assert_equal 0, moves("receive").count
    assert_equal 0, moves("putaway").count
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

  test "자재 부족이면 그 분은 건너뛰고(이동 0), 칸에 재고가 들어오면 다음 분에 소비를 재개한다" do
    stock(@steel, 10) # 100개 생산에 200 필요
    stock(@bolt, 10_000)
    event(M0 - 20, 100)

    a = run_minute(0)
    assert_equal [0, 1], [a[:backflush], a[:skipped]]
    assert_equal 0, moves("produce").count
    assert_equal 0, moves("issue").count, "볼트는 충분했지만 전체가 롤백돼 아무것도 빠지지 않는다"
    assert_equal 10, store_qty(@steel)
    assert_equal 0, moves("receive").where("idempotency_key LIKE 'sim:%'").count, "Logistics 는 트럭을 부르지 않는다"

    stock(@steel, 500)
    b = run_minute(1)
    assert_equal [1, 0], [b[:backflush], b[:skipped]]
    assert_equal 100, moves("produce").sum(:qty)
    assert_equal 310, store_qty(@steel)
    assert_equal 0, Quant.joins(:location).where(locations: { kind: "physical" }).where("quants.qty < 0").count
    assert_equal [], Inventory::Reconcile.call
  end

  test "칸이 여럿이면 코드 순으로 차감하고, 한 칸이 모자라면 다음 칸에서 이어 뺀다" do
    lot_a = Lot.create!(product: @steel, lot_no: "R-T-A")
    lot_b = Lot.create!(product: @steel, lot_no: "R-T-B")
    stock(@steel, 150, bin: BIN2, lot: lot_b) # 코드가 뒤인 칸을 먼저 채워도
    stock(@steel, 100, bin: BIN1, lot: lot_a) # 앞 칸부터 빠진다
    stock(@bolt, 500)
    event(M0 - 20, 100) # 강판 200, 볼트 100

    run_minute(0)

    steel_issues = moves("issue").where(product_id: @steel.id).order(:id).to_a
    assert_equal [BIN1, BIN2], steel_issues.map { |m| m.from_location.code }
    assert_equal [100, 100], steel_issues.map { |m| m.qty.to_i }
    assert_equal [lot_a.id, lot_b.id], steel_issues.map(&:lot_id), "빼는 이동이 칸의 로트를 그대로 따른다"
    assert_equal 0, bin_qty(@steel, BIN1)
    assert_equal 50, bin_qty(@steel, BIN2)
    assert_equal 400, bin_qty(@bolt, BIN1)
    assert_equal [], Inventory::Reconcile.call
  end

  test "칸이 생기기 전 raw_store 자체의 재고는 칸 재고 다음에 쓴다" do
    stock(@steel, 50, bin: BIN1)
    stock(@steel, 200, bin: "raw_store")
    stock(@bolt, 500)
    event(M0 - 20, 100)

    run_minute(0)

    assert_equal 0, bin_qty(@steel, BIN1)
    assert_equal 50, bin_qty(@steel, "raw_store"), "칸 50 을 먼저 쓰고 나머지 150 을 자체 재고에서"
    assert_equal ["raw_store"], moves("issue").where(product_id: @steel.id).order(:id).last(1).map { |m| m.from_location.code }
  end

  test "issue 멱등키는 issue:<작업지시>:<자재>:<칸>:<로트>:<분 ISO> 이다" do
    stock(@steel, 1000)
    stock(@bolt, 1000)
    event(M0 - 20, 10)
    run_minute(0)

    bin = Location.find_by!(code: BIN1)
    assert_equal ["issue:#{@order.id}:#{@steel.id}:#{bin.id}:0:2026-10-08T12:00:00Z"],
                 moves("issue").where(product_id: @steel.id).pluck(:idempotency_key)
  end
end
