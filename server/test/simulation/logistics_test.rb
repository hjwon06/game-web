require "test_helper"
require "stringio"

class LogisticsTest < ActiveSupport::TestCase
  M0 = Time.utc(2026, 10, 8, 12, 0, 0)
  EPOCH = M0 - 3600

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
  end

  teardown do
    @old_epoch.nil? ? ENV.delete("INVENTORY_EPOCH") : ENV["INVENTORY_EPOCH"] = @old_epoch
  end

  def stock(product, qty)
    Inventory::Move.call(product: product, lot: nil, from: "supplier", to: "receiving", qty: qty, move_type: "receive",
                         ref: nil, idempotency_key: "test-recv-#{product.id}-#{qty}")
    Inventory::Move.call(product: product, lot: nil, from: "receiving", to: "raw_store", qty: qty, move_type: "putaway",
                         ref: nil, idempotency_key: "test-put-#{product.id}-#{qty}")
  end

  def event(at, good)
    ProductionEvent.create!(machine: @machine, work_order: @order, bucket_start: at, bucket_end: at + 10,
                            good_qty: good, defect_qty: 0, machine_version: 0)
  end

  def run_minute(n)
    Simulation::Logistics.call(now: M0 + (n * 60), logger: Logger.new(@log))
  end

  def qty_at(product, code)
    Quant.joins(:location).where(product_id: product.id, lot_id: nil, locations: { code: code }).sum(:qty)
  end

  def moves(type) = StockMove.where(move_type: type)

  # setup 의 stock() 이 만든 receive·putaway 는 빼고 Logistics 가 만든 것만.
  def sim_moves(type) = moves(type).where("idempotency_key LIKE 'sim:%'")

  test "EPOCH 이전 생산은 소비하지 않는다" do
    stock(@steel, 1000)
    stock(@bolt, 1000)
    event(EPOCH - 10, 50) # 이전
    event(EPOCH, 20)      # 경계 포함
    event(M0 - 20, 5)

    run_minute(0)

    assert_equal 25, moves("produce").sum(:qty)
    assert_equal 950, qty_at(@steel, "raw_store")
    assert_equal 975, qty_at(@bolt, "raw_store")
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

  test "같은 분을 두 번 실행해도 이동이 늘지 않는다" do
    stock(@steel, 1000)
    stock(@bolt, 1000)
    event(M0 - 20, 30)

    first = run_minute(0)
    before = StockMove.count
    again = run_minute(0)

    assert_operator before, :>, 4
    assert_equal before, StockMove.count
    assert_equal 1, first[:backflush]
    assert_equal 0, again[:backflush]
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

  test "자재 부족 → 소비 건너뜀 + 트럭 1건 → 다음 분 적치 → 그다음 분 소비 재개" do
    stock(@steel, 10) # 100개 생산에 200 필요
    stock(@bolt, 10_000)
    event(M0 - 20, 100)

    a = run_minute(0)
    assert_equal [0, 1, 1], [moves("produce").count, a[:skipped], a[:receive]]
    assert_equal ["RAW-S"], sim_moves("receive").map { |m| m.product.sku }
    assert_equal 10, qty_at(@steel, "raw_store"), "입고대에만 있고 아직 적치 전이다"

    b = run_minute(1)
    assert_equal [0, 1, 1], [moves("produce").count, b[:skipped], b[:putaway]], "적치는 소비 뒤라 이 분에도 소비는 막혀 있다"
    assert_equal 0, b[:receive]
    assert_operator qty_at(@steel, "raw_store"), :>, 200

    c = run_minute(2)
    assert_equal [1, 0, 0], [moves("produce").count, c[:skipped], c[:receive]]
    assert_equal 100, moves("produce").sum(:qty)
    assert_equal 1, sim_moves("receive").count
    assert_equal 0, Quant.joins(:location).where(locations: { kind: "physical" }).where("quants.qty < 0").count
    assert_equal [], Inventory::Reconcile.call
  end

  test "트럭은 30분치 + 못 뺀 양을 싣는다" do
    stock(@steel, 10)
    stock(@bolt, 10_000)
    event(M0 - 20, 100)
    run_minute(0)

    # 강판 양품 0.784/s x 2 = 1.568/s → 1800초 = 2822.4 → 2823, 거기에 못 뺀 200
    assert_equal 2823 + 200, sim_moves("receive").sum(:qty)
  end

  test "같은 자재 트럭은 5분에 한 번이다" do
    stock(@bolt, 10_000)
    run_minute(0)
    assert_equal 1, sim_moves("receive").count
    run_minute(1) # 적치
    drain(@steel)

    (2..4).each do |n|
      run_minute(n)
      assert_equal 1, sim_moves("receive").count, "#{n}분: 5분 안이라 트럭이 없다"
    end
    run_minute(5)
    assert_equal 2, sim_moves("receive").count
  end

  test "같은 분 재실행은 이번 분에 받은 트럭을 적치하지 않는다" do
    stock(@bolt, 10_000)
    run_minute(0)
    count = StockMove.count
    run_minute(0)

    assert_equal count, StockMove.count
    assert_equal 0, sim_moves("putaway").count
  end

  test "멱등키는 sim:<종류>:<품목 id>:<분 ISO> 이다" do
    stock(@bolt, 10_000)
    run_minute(0)
    run_minute(1)

    assert_equal ["sim:receive:#{@steel.id}:2026-10-08T12:00:00Z"], sim_moves("receive").pluck(:idempotency_key)
    assert_equal ["sim:putaway:#{@steel.id}:2026-10-08T12:01:00Z"], sim_moves("putaway").pluck(:idempotency_key)
  end

  test "하루 예상 이동 행 수를 로그 한 줄로 남긴다" do
    stock(@steel, 10_000)
    stock(@bolt, 10_000)
    result = run_minute(0)

    # 분당 issue 2 + produce 1 = 3행 x 1440 + 자재 2종 x (receive+putaway) x 하루 트럭 수(86400 / 1200)
    assert_equal (3 * 1440) + (2 * 2 * 72), result[:est_daily_moves]
    assert_equal 1, @log.string.lines.grep(/est_daily_moves=#{result[:est_daily_moves]}/).size
  end

  test "stopped 기계는 소비 예상에 넣지 않아 트럭이 없다" do
    @machine.update!(state: "stopped")
    run_minute(0)
    assert_equal 0, sim_moves("receive").count
  end

  private

  def drain(product)
    qty = qty_at(product, "raw_store")
    Inventory::Move.call(product: product, lot: nil, from: "raw_store", to: "production", qty: qty, move_type: "issue",
                         ref: nil, idempotency_key: "test-drain-#{product.id}") if qty.positive?
  end
end
