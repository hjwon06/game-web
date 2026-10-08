require "test_helper"
require "stringio"

# B2: 검사 → 출하 → 신규 수주
class LogisticsFulfillmentTest < ActiveSupport::TestCase
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

  def event(good, defect)
    ProductionEvent.create!(machine: @machine, work_order: @order, bucket_start: M0 - 600, bucket_end: M0 - 590,
                            good_qty: good, defect_qty: defect, machine_version: 0)
  end

  # Backflush 가 만드는 것과 같은 모양(로트 = 작업지시 코드, 키 produce:<작업지시>:<분 ISO>)으로 qc 에 쌓는다.
  def produce_to_qc(qty, at)
    lot = Lot.find_or_create_by!(product: @fg, lot_no: @order.code)
    Inventory::Move.call(product: @fg, lot: lot, from: "production", to: "qc", qty: qty, move_type: "produce",
                         ref: @order, idempotency_key: "produce:#{@order.id}:#{at.utc.iso8601}")
    lot
  end

  def qty_at(code, lot = nil)
    Quant.joins(:location).where(product_id: @fg.id, locations: { code: code }).then { |q| lot ? q.where(lot_id: lot.id) : q }.sum(:qty)
  end

  def sales_order(so_no, due, qty)
    so = SalesOrder.create!(so_no: so_no, customer: "한빛정공", due_date: due, status: "open")
    so.lines.create!(product: @fg, ordered_qty: qty)
  end

  def fg_stock(qty)
    lot = Lot.find_or_create_by!(product: @fg, lot_no: "LOT-STOCK")
    Inventory::Move.call(product: @fg, lot: lot, from: "production", to: "qc", qty: qty, move_type: "produce",
                         ref: nil, idempotency_key: "t-prod-#{SecureRandom.hex(4)}")
    Inventory::Inspect.call(lot: lot, work_order: @order, pass_qty: qty, fail_qty: 0, idempotency_key: "t-qc-#{SecureRandom.hex(4)}")
    lot
  end

  test "qc 2분 이하 머문 로트는 검사하지 않고, 2분을 넘기면 검사한다" do
    event(90, 10)
    produce_to_qc(100, M0)

    [0, 1, 2].each do |n|
      assert_equal 0, run_minute(n)[:inspect], "#{n}분: 도착 후 #{n * 60}초라 아직이다"
    end
    assert_equal 100, qty_at("qc")

    assert_equal 1, run_minute(3)[:inspect]
    assert_equal 0, qty_at("qc")
  end

  test "불합격 수량은 EPOCH 이후 불량률 x 검사 수량을 반올림한다" do
    event(90, 10) # 10%
    ProductionEvent.create!(machine: @machine, work_order: @order, bucket_start: EPOCH - 100, bucket_end: EPOCH - 90,
                            good_qty: 0, defect_qty: 5_000, machine_version: 0) # EPOCH 이전은 무시
    produce_to_qc(125, M0 - 300)

    run_minute(0)

    assert_equal 13, StockMove.where(move_type: "qc_fail").sum(:qty) # 12.5 → 13
    assert_equal 112, StockMove.where(move_type: "qc_pass").sum(:qty)
    assert_equal 13, qty_at("scrap")
  end

  test "불량률 0 이면 qc_fail 이 없다" do
    event(100, 0)
    produce_to_qc(50, M0 - 300)

    run_minute(0)

    assert_equal 0, StockMove.where(move_type: "qc_fail").count
    assert_equal 50, StockMove.where(move_type: "qc_pass").sum(:qty)
  end

  test "검사는 같은 분에 다시 불려도 늘지 않고 새 도착분만 다음 분에 검사한다" do
    # 생산 good 을 qc 도착량(50)과 같게 둔다. 100 이면 B1 백플러시가 차액 50 을 따로 만들어 검사량이 섞인다
    event(50, 0)
    produce_to_qc(50, M0 - 300)
    run_minute(0)
    before = StockMove.count
    assert_equal 0, run_minute(0)[:inspect]
    assert_equal before, StockMove.count

    produce_to_qc(7, M0 + 60)
    assert_equal 0, run_minute(2)[:inspect]
    assert_equal 1, run_minute(4)[:inspect]
    assert_equal 57, StockMove.where(move_type: "qc_pass").sum(:qty)
  end

  test "재고 부족 수주는 가능한 만큼 partial, 이후 재고가 생기면 done" do
    line = sales_order("SO-T-1", Date.new(2026, 10, 1), 100)
    fg_stock(30)

    assert_equal 1, run_minute(0)[:ship]
    assert_equal 30, StockMove.where(move_type: "ship", ref_id: line.id).sum(:qty)
    assert_equal "partial", line.sales_order.reload.status

    fg_stock(100)
    run_minute(1)
    assert_equal 100, StockMove.where(move_type: "ship", ref_id: line.id).sum(:qty)
    assert_equal "done", line.sales_order.reload.status
    assert_equal 0, run_minute(2)[:ship]
  end

  test "납기 빠른 순으로 한 분에 수주 3건까지만 출하한다" do
    lines = [5, 4, 3, 2, 1].map { |d| sales_order("SO-T-#{d}", Date.new(2026, 10, 1) + d, 10) }
    fg_stock(1000)

    result = run_minute(0)

    assert_equal 3, result[:ship]
    shipped = SalesOrder.where(status: "done").pluck(:so_no)
    assert_equal %w[SO-T-1 SO-T-2 SO-T-3], shipped.sort

    again = run_minute(0)
    assert_equal 0, again[:ship], "같은 분 재실행은 4번째 수주로 번지지 않는다"
    assert_equal 30, StockMove.where(move_type: "ship").sum(:qty)
    # lines 는 [5,4,3,2,1] 일수 순이라 last(2) 는 납기가 가장 빠른(=이미 출하된) SO-T-2, SO-T-1 이다. so_no 로 직접 본다.
    assert_equal({ "SO-T-4" => "open", "SO-T-5" => "open" }, SalesOrder.where(so_no: %w[SO-T-4 SO-T-5]).pluck(:so_no, :status).to_h)
  end

  test "출하 멱등키는 sim:ship:<라인 id>:<분 ISO> 이다" do
    line = sales_order("SO-T-1", Date.new(2026, 10, 1), 10)
    fg_stock(10)
    run_minute(0)

    assert_equal ["sim:ship:#{line.id}:2026-10-08T12:00:00Z"], StockMove.where(move_type: "ship").pluck(:idempotency_key)
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

  test "C2 가 실패해도 C3 은 실행되고 실패는 로그 1줄이다" do
    sales_order("SO-T-1", Date.new(2026, 10, 1), 10)
    fg_stock(10)

    # minitest 6 에는 stub 이 없어 클래스 메서드를 직접 바꿨다 되돌린다.
    original = Inventory::Ship.method(:call)
    Inventory::Ship.define_singleton_method(:call) { |**| raise "주입된 실패" }
    begin
      result = run_minute(0)
    ensure
      Inventory::Ship.define_singleton_method(:call, original)
    end

    assert_equal 0, result[:ship]
    assert_equal 1, result[:order]
    assert_equal 1, @log.string.lines.grep(/sim logistics ship line=.*주입된 실패/).size
  end

  test "단계 전체가 터져도 다음 단계는 실행된다" do
    sales = Simulation::Logistics.instance_method(:ship_orders)
    Simulation::Logistics.send(:define_method, :ship_orders) { raise "단계 실패" }
    begin
      result = run_minute(0)
    ensure
      Simulation::Logistics.send(:define_method, :ship_orders, sales)
    end

    assert_equal 1, result[:order]
    assert_equal 1, @log.string.lines.grep(/sim logistics ship .*단계 실패/).size
  end

  test "catch_up 이 터져도 입고·검사·출하·수주는 실행된다" do
    event(90, 10)
    produce_to_qc(100, M0 - 300)
    sales_order("SO-T-1", Date.new(2026, 10, 1), 10)

    original = Simulation::Logistics.instance_method(:catch_up)
    Simulation::Logistics.send(:define_method, :catch_up) { |*| raise "catch_up 실패" }
    begin
      result = run_minute(0)
    ensure
      Simulation::Logistics.send(:define_method, :catch_up, original)
    end

    assert_equal [1, 1, 1], [result[:inspect], result[:ship], result[:order]]
    assert_equal 1, @log.string.lines.grep(/sim logistics backflush .*catch_up 실패/).size
  end

  test "한 단계의 PG 오류는 그 단계만 되돌리고 다음 단계는 정상이다" do
    event(90, 10)
    produce_to_qc(100, M0 - 300)

    original = Simulation::Logistics.instance_method(:ship_orders)
    Simulation::Logistics.send(:define_method, :ship_orders) do
      Quant.insert_all([{ product_id: -1, location_id: -1, qty: 1 }]) # 없는 FK → PG 오류, 트랜잭션 aborted
    end
    begin
      result = run_minute(0)
    ensure
      Simulation::Logistics.send(:define_method, :ship_orders, original)
    end

    assert_equal 1, result[:inspect], "앞 단계 결과는 남는다"
    assert_equal 90, qty_at("fg_store") # 100 중 불량률 10% 는 scrap
    assert_equal 1, result[:order], "뒤 단계는 aborted 트랜잭션에 걸리지 않는다"
    assert_equal 1, SalesOrder.count
    assert_equal 1, @log.string.lines.grep(/sim logistics ship .*ForeignKey/).size
    assert_equal 1, @log.string.lines.grep(/ERROR/).size
  end

  test "같은 분 재실행 사이에 qc 재고가 늘어도 검사는 이번 분에 다시 하지 않는다" do
    event(50, 0)
    produce_to_qc(50, M0 - 300)
    assert_equal 1, run_minute(0)[:inspect]

    produce_to_qc(7, M0 - 240) # 2분을 넘긴 도착분이 같은 분 안에 추가됐다
    before = StockMove.count
    assert_equal 0, run_minute(0)[:inspect]
    assert_equal before, StockMove.count
    assert_equal [], @log.string.lines.grep(/ERROR|IdempotencyConflict/)

    assert_equal 1, run_minute(1)[:inspect]
    assert_equal 57, StockMove.where(move_type: "qc_pass").sum(:qty)
  end

  test "이어서 돌려도 물리 위치가 마이너스가 되지 않고 Reconcile 이 0 이다" do
    event(90, 10)
    produce_to_qc(100, M0 - 300)
    sales_order("SO-T-1", Date.new(2026, 10, 1), 500)
    (0..4).each { |n| run_minute(n) }

    assert_equal 0, Quant.joins(:location).where(locations: { kind: "physical" }).where("quants.qty < 0").count
    assert_equal [], Inventory::Reconcile.call
  end
end
