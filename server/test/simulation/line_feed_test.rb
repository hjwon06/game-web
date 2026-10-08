require "test_helper"
require "stringio"

# 라인 공급: line_side 재고 < 다음 10분 소비 예상이면 raw 칸에서 line_side 로 feed 작업 1팔레트(FIFO 칸).
class LineFeedTest < ActiveSupport::TestCase
  M0 = Time.utc(2026, 10, 8, 12, 0, 0)
  EPOCH = M0 - 3600
  BIN1 = "RAW-A-01-01".freeze
  BIN2 = "RAW-A-01-02".freeze

  setup do
    @old_epoch = ENV["INVENTORY_EPOCH"]
    ENV["INVENTORY_EPOCH"] = EPOCH.iso8601
    Resource.ensure_defaults!
    Ops::Plan.reseed!(5)
    @steel = Product.create!(sku: "RAW-S", name: "강판", uom: "ea", kind: "raw")
    @bolt = Product.create!(sku: "RAW-B", name: "볼트", uom: "ea", kind: "raw")
    @fg = Product.create!(sku: "FG-BR", name: "브래킷", uom: "ea", kind: "fg")
    BomLine.create!(product: @fg, component: @steel, qty_per: 2) # M1 양품 0.784/s → 10분 강판 940.8, 볼트 470.4
    BomLine.create!(product: @fg, component: @bolt, qty_per: 1)
    @machine = Machine.create!(code: "M1", name: "절단기", state: "running")
    @order = WorkOrder.create!(code: "WO-LF", machine: @machine, item: @fg, product: "브래킷", target_qty: 100_000,
                               status: "active", started_at: M0)
    @log = StringIO.new
    @line_side = Location.find_by!(code: "line_side")
    @seq = 0
  end

  teardown do
    @old_epoch.nil? ? ENV.delete("INVENTORY_EPOCH") : ENV["INVENTORY_EPOCH"] = @old_epoch
  end

  def feed(now = M0) = Simulation::LineFeed.call(now: now, logger: Logger.new(@log))

  def feeds = Task.where(kind: "feed").order(:id)

  def far_future = Time.current + 1.day

  # raw 칸에 재고를 만든다(입고 → 적치). 용량 때문에 칸 용량은 넉넉히 키운다.
  def raw_stock(product, bin, qty, lot: nil)
    Location.where(code: bin).update_all(capacity_units: 1_000_000)
    Inventory::Move.call(product: product, lot: lot, from: "supplier", to: "receiving", qty: qty, move_type: "receive",
                         ref: nil, idempotency_key: "lf-recv-#{@seq += 1}")
    Inventory::Move.call(product: product, lot: lot, from: "receiving", to: bin, qty: qty, move_type: "putaway",
                         ref: nil, idempotency_key: "lf-put-#{@seq += 1}")
  end

  def line_stock(product, qty)
    raw_stock(product, BIN2, qty)
    Inventory::Move.call(product: product, lot: nil, from: BIN2, to: "line_side", qty: qty, move_type: "feed", ref: nil,
                         idempotency_key: "lf-line-#{@seq += 1}")
  end

  def qty_at(product, code)
    Quant.joins(:location).where(product_id: product.id, locations: { code: code }).sum(:qty)
  end

  test "line_side 가 비면 자재마다 feed 1건(팔레트 1개)이 지게차에 계획된다. 재고는 아직 안 움직인다" do
    raw_stock(@steel, BIN1, 500)
    raw_stock(@bolt, BIN1, 500)
    base = StockMove.count

    result = feed

    assert_equal [2, 0], [result[:feed], result[:waiting]]
    assert_equal [@steel.id, @bolt.id].sort, feeds.map(&:product_id).sort
    feeds.each do |t|
      assert_equal [Simulation::Config::PALLET_QTY, "planned", "forklift", BIN1, "line_side"],
                   [t.qty.to_i, t.status, t.resource.kind, t.from_location.code, t.to_location.code]
    end
    assert_equal base, StockMove.count
  end

  test "같은 시각에 다시 불러도 작업이 늘지 않고, 같은 자재의 feed 가 planned/started 인 동안은 추가 계획이 없다" do
    raw_stock(@steel, BIN1, 500)
    raw_stock(@bolt, BIN1, 500)
    feed

    assert_equal 0, feed[:feed]
    assert_equal 2, feeds.count

    Ops::Tick.call(now: feeds.maximum(:planned_at) + 1.second) # 일부는 started
    assert_equal 0, feed(M0 + 60)[:feed]
    assert_equal 2, feeds.count
  end

  test "line_side 재고가 다음 10분 예상 소비 이상이면 feed 하지 않는다" do
    Location.where(id: @line_side.id).update_all(capacity_units: 1_000_000)
    line_stock(@steel, 1000) # 필요 940.8
    line_stock(@bolt, 500)   # 필요 470.4
    raw_stock(@steel, BIN1, 500)

    assert_equal 0, feed[:feed]
    assert_equal 0, feeds.count
  end

  test "부족한 자재만 공급한다" do
    Location.where(id: @line_side.id).update_all(capacity_units: 1_000_000)
    line_stock(@steel, 1000)
    raw_stock(@steel, BIN1, 500)
    raw_stock(@bolt, BIN1, 500)

    feed

    assert_equal [@bolt.id], feeds.map(&:product_id)
  end

  test "FIFO: 로트가 가장 오래된 칸에서 먼저 공급하고, 로트 시각이 같으면 칸 코드 순이다" do
    old_lot = Lot.create!(product: @steel, lot_no: "R-OLD", created_at: M0 - 7200, updated_at: M0 - 7200)
    new_lot = Lot.create!(product: @steel, lot_no: "R-NEW", created_at: M0 - 3600, updated_at: M0 - 3600)
    raw_stock(@steel, BIN1, 300, lot: new_lot) # 코드가 앞이어도 로트가 늦다
    raw_stock(@steel, BIN2, 300, lot: old_lot)

    feed

    task = feeds.find_by!(product_id: @steel.id)
    assert_equal [BIN2, old_lot.id], [task.from_location.code, task.lot_id]
  end

  test "로트 시각이 같으면 칸 코드가 앞선 칸" do
    same = M0 - 3600
    a = Lot.create!(product: @steel, lot_no: "R-A", created_at: same, updated_at: same)
    b = Lot.create!(product: @steel, lot_no: "R-B", created_at: same, updated_at: same)
    raw_stock(@steel, BIN2, 300, lot: b)
    raw_stock(@steel, BIN1, 300, lot: a)

    feed

    assert_equal [BIN1, a.id], feeds.find_by!(product_id: @steel.id).then { |t| [t.from_location.code, t.lot_id] }
  end

  test "고른 칸에 팔레트 1개만큼이 없으면 남은 만큼만 공급한다" do
    raw_stock(@steel, BIN1, 60)

    feed

    assert_equal [60], feeds.where(product_id: @steel.id).map { |t| t.qty.to_i }
  end

  test "line_side 재고 / 분당 소비가 가장 작은 자재부터 계획한다: 부족분이 더 커도 버틸 시간이 긴 자재는 뒤다" do
    line_stock(@steel, 300) # 분당 94.08 → 3.2분 버틴다. 부족분 640.8
    line_stock(@bolt, 100)  # 분당 47.04 → 2.1분 버틴다. 부족분 370.4
    raw_stock(@steel, BIN1, 500)
    raw_stock(@bolt, BIN1, 500)
    Location.where(id: @line_side.id).update_all(capacity_units: 900) # 보유 400 → 여유 500: 한 자재만 채울 수 있다

    result = feed

    assert_equal [1, 1], [result[:feed], result[:waiting]]
    assert_equal [@bolt.id], feeds.map(&:product_id)
  end

  test "원천 재고가 없는 자재는 계획하지 않고 waiting 으로 센다" do
    raw_stock(@steel, BIN1, 500)

    result = feed

    assert_equal [1, 1], [result[:feed], result[:waiting]]
    assert_equal [@steel.id], feeds.map(&:product_id)
  end

  test "line_side 용량을 넘기지 않게 현재고 + 진행 중 feed 를 뺀 여유까지만 계획한다" do
    line_stock(@bolt, Location::LINE_SIDE_CAPACITY - 20) # 볼트 필요 470.4 이라 충분. 여유 20
    raw_stock(@steel, BIN1, 500)

    feed

    assert_equal [20], feeds.map { |t| t.qty.to_i }
    assert_equal [@steel.id], feeds.map(&:product_id)
  end

  test "활성 작업지시가 없거나 기계가 멈췄으면 소비 예상이 없어 계획하지 않는다" do
    raw_stock(@steel, BIN1, 500)
    @machine.update!(state: "stopped")

    assert_equal 0, feed[:feed]
    assert_equal 0, feeds.count
  end

  test "소비 → line_side 부족 → feed 계획 → 완료 후 백플러시 재개" do
    raw_stock(@steel, BIN1, 500)
    raw_stock(@bolt, BIN1, 500)
    ProductionEvent.create!(machine: @machine, work_order: @order, bucket_start: M0 - 20, bucket_end: M0 - 10,
                            good_qty: 100, defect_qty: 0, machine_version: 0) # 강판 200, 볼트 100 필요
    logistics = ->(n) { Simulation::Logistics.call(now: M0 + (n * 60), logger: Logger.new(@log)) }

    a = logistics.call(0)
    assert_equal [0, 1], [a[:backflush], a[:skipped]]

    feed
    Ops::Tick.call(now: far_future) # 팔레트 1개(500)가 한 번에 들어온다
    assert_equal Simulation::Config::PALLET_QTY, qty_at(@steel, "line_side")
    assert_equal 2, StockMove.where(move_type: "feed").count, "강판 1 + 볼트 1"
    assert_equal 2, feeds.where(status: "done").count

    b = logistics.call(1)
    assert_equal [1, 0], [b[:backflush], b[:skipped]]
    assert_equal Simulation::Config::PALLET_QTY - 200, qty_at(@steel, "line_side")
    assert_equal Simulation::Config::PALLET_QTY - 100, qty_at(@bolt, "line_side"), "볼트는 100 쓰고 나머지가 남는다"
    assert_equal 100, StockMove.where(move_type: "produce").sum(:qty)
    assert_equal [], Inventory::Reconcile.call
  end

  test "D5: 다른 미완료 작업이 이미 잡은 수량은 가용 재고에서 빼고 계획한다. 전부 잡혀 있으면 계획하지 않는다" do
    raw_stock(@steel, BIN1, 700)
    Ops::Plan.call(kind: "putaway", product: @steel, lot: nil, qty: 500, from: BIN1, to: BIN2, ref: nil, earliest_at: M0)

    feed

    assert_equal [200], feeds.where(product_id: @steel.id).map { |t| t.qty.to_i }, "700 - 이미 잡힌 500"

    Ops::Plan.call(kind: "pick", product: @bolt, lot: nil, qty: 300, from: BIN1, to: "shipping", ref: nil, earliest_at: M0)
    raw_stock(@bolt, BIN1, 300)
    again = feed(M0 + 10)

    assert_equal 1, again[:waiting], "볼트 300 은 이미 pick 이 잡았다"
    assert_empty feeds.where(product_id: @bolt.id)
  end

  test "D4: 수요/공급 비는 est_feed_per_min 과 forklift_capacity_per_min 으로 나오고 팔레트 500 이면 처리량의 절반 이하다" do
    balance = Simulation::LineFeed.new(now: M0, logger: Logger.new(@log)).balance

    # M1 양품 0.784/s x (BOM 2 + 1) x 60 = 141.1/min → 팔레트 500 이면 0.28회/min. 지게차 2대 x 60 / 40초 = 3.0회/min
    assert_in_delta 0.28, balance[:est_feed_per_min], 0.01
    assert_in_delta 3.0, balance[:forklift_capacity_per_min], 0.01
    assert_operator balance[:est_feed_per_min], :<=, balance[:forklift_capacity_per_min] / 2
    assert_equal [500, 2000], [Simulation::Config::PALLET_QTY, Location::BIN_CAPACITY]
  end

  test "feed 완료는 이동 1건(feed)이고 line_side 용량을 넘으면 그 작업만 취소된다" do
    raw_stock(@steel, BIN1, 500)
    t = Ops::Plan.call(kind: "feed", product: @steel, lot: nil, qty: Simulation::Config::PALLET_QTY, from: BIN1, to: "line_side", ref: nil, earliest_at: Time.current)
    Location.where(id: @line_side.id).update_all(capacity_units: 50)

    Ops::Tick.call(now: far_future)

    assert_equal "cancelled", t.reload.status
    assert_match(/CapacityExceeded/, t.cancel_reason)
    assert_equal 0, StockMove.where(move_type: "feed").count
  end
end
