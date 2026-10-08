require "test_helper"
require "stringio"

# Logistics 의 신규 수주 단계와 단계 격리. 검사는 inspection_test.rb, 출하는 shipping_test.rb 로 옮겼다.
class LogisticsFulfillmentTest < ActiveSupport::TestCase
  include UnscaledRatesHelper
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

  # M0 - 10분부터 10분 간격 5개 구간에 구간당 good 개 생산한 기록. 어느 분에 돌려도 룩백(30분) 안에 1개 이상 들어간다.
  def produce_history(good)
    5.times do |k|
      start = M0 + ((k - 1) * 600)
      ProductionEvent.create!(machine: @machine, work_order: @order, bucket_start: start, bucket_end: start + 10,
                              good_qty: good, defect_qty: 0, machine_version: 0)
    end
  end

  def run_minute(n)
    Simulation::Logistics.call(now: M0 + (n * 60), logger: Logger.new(@log))
  end

  test "Logistics 는 검사·출하를 하지 않는다: qc 와 fg 재고가 있어도 qc_pass·qc_fail·pick·ship 이동이 없다" do
    lot = Lot.find_or_create_by!(product: @fg, lot_no: @order.code)
    Inventory::Move.call(product: @fg, lot: lot, from: "production", to: "qc", qty: 100, move_type: "produce", ref: @order,
                         idempotency_key: "produce:#{@order.id}:#{(M0 - 600).iso8601}")
    so = SalesOrder.create!(so_no: "SO-T-1", customer: "한빛정공", due_date: Date.new(2026, 10, 1), status: "open")
    so.lines.create!(product: @fg, ordered_qty: 10)

    5.times { |n| run_minute(n) }

    %w[qc_pass qc_fail pick ship].each { |type| assert_equal 0, StockMove.where(move_type: type).count, type }
    assert_equal 0, Task.count
  end

  test "신규 수주는 10분에 1건이고 같은 분 재실행으로 늘지 않는다" do
    produce_history(9000)
    run = (0..9).map { |n| run_minute(n)[:order] }

    assert_equal [1, 0, 0, 0, 0, 0, 0, 0, 0, 0], run
    assert_equal 1, SalesOrder.count
    assert_equal 0, run_minute(0)[:order], "같은 분 재실행"
    assert_equal 1, SalesOrder.count

    assert_equal 1, run_minute(10)[:order]
    assert_equal 2, SalesOrder.count
  end

  test "신규 수주 모양: 연번 so_no, 고객 순환, 라인 1~2, 납기 1~3일" do
    produce_history(9000)
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

  test "신규 수주 수량 = 최근 30분 양품 생산량 x 10/30 x 0.9 를 ORDER_UNIT 단위로 내림" do
    produce_history(9000) # 분 0 의 룩백(M0-30분..M0)에는 M0-10분 구간 하나만 들어간다
    run_minute(0)

    assert_equal [2700], SalesOrderLine.pluck(:ordered_qty) # 9000 x 0.3 = 2700 → 2700
  end

  test "신규 수주 수량은 생산량에 비례한다" do
    produce_history(18_000)
    run_minute(0)

    assert_equal [5400], SalesOrderLine.pluck(:ordered_qty) # 18000 x 0.3 = 5400 → 5400
  end

  test "실측 규모(30분 양품 610): 수주 1건, 수량 > 0, ORDER_UNIT 의 배수" do
    produce_history(610) # 610 x 0.3 = 183 → 180
    assert_equal 1, run_minute(0)[:order]

    assert_equal [180], SalesOrderLine.pluck(:ordered_qty)
    assert SalesOrderLine.pluck(:ordered_qty).all? { |q| q.positive? && (q % Simulation::Config::ORDER_UNIT).zero? }
  end

  test "실측 규모(30분 양품 1018, 수요 품목 1개) → 305.4 를 300 으로 내림. n=1 이면 보정 없음" do
    produce_history(1018) # 1018 x 0.3 = 305.4 → 300
    run_minute(0)

    assert_equal [300], SalesOrderLine.pluck(:ordered_qty)
  end

  test "생산이 보정 후에도 ORDER_UNIT 에 못 미치면 줄이 없고 수주 0 이다. 룩백 밖 생산은 세지 않는다" do
    produce_history(20) # 20 x 0.3 = 6 < 10
    ProductionEvent.create!(machine: @machine, work_order: @order, bucket_start: M0 - 7200, bucket_end: M0 - 7190,
                            good_qty: 90_000, defect_qty: 0, machine_version: 0)

    assert_equal 0, run_minute(0)[:order]
    assert_equal 0, SalesOrder.count
    assert_equal 0, SalesOrderLine.count
  end

  test "수요 품목 5개 중 k 개를 고르면 고른 품목 수량에 5/k 를 곱한 뒤 ORDER_UNIT 으로 내린다" do
    orders = [@order] + (2..5).map do |i|
      fg = Product.create!(sku: "FG-#{i}", name: "품목#{i}", uom: "ea", kind: "fg")
      machine = Machine.create!(code: "M#{i}", name: "기계#{i}", state: "running")
      WorkOrder.create!(code: "WO-F#{i}", machine: machine, item: fg, product: "품목#{i}", target_qty: 100_000,
                        status: "active", started_at: M0)
    end
    orders.each do |wo|
      ProductionEvent.create!(machine: wo.machine, work_order: wo, bucket_start: M0 - 600, bucket_end: M0 - 590,
                              good_qty: 610, defect_qty: 0, machine_version: 0)
    end

    seen = []
    (0..9).each do |m|
      SalesOrderLine.delete_all
      SalesOrder.delete_all
      run_minute(m)
      lines = SalesOrderLine.all.to_a
      next if lines.empty?

      k = lines.size
      seen << k
      # 품목당 기본 수요 610 x 0.3 = 183. k=1 → 183 x 5 = 915 → 910, k=2 → 183 x 5/2 = 457.5 → 450
      expected = { 1 => 910, 2 => 450 }.fetch(k)
      assert_equal [expected] * k, lines.map(&:ordered_qty), "k=#{k}"
    end
    assert_not_empty seen
  end

  test "두 품목이 함께 골렸는데 한 품목이 보정·내림 후 0 이면 그 줄만 빠지고 수주는 1건 만들어진다" do
    fg_b = Product.create!(sku: "FG-B", name: "품목B", uom: "ea", kind: "fg")
    machine_b = Machine.create!(code: "M2", name: "기계2", state: "running")
    order_b = WorkOrder.create!(code: "WO-F2", machine: machine_b, item: fg_b, product: "품목B", target_qty: 100_000,
                                status: "active", started_at: M0)
    # 룩백(30분)에 M0-10분 구간 하나만 들어가는 분은 0..20 이다.
    ProductionEvent.create!(machine: @machine, work_order: @order, bucket_start: M0 - 600, bucket_end: M0 - 590,
                            good_qty: 610, defect_qty: 0, machine_version: 0)
    ProductionEvent.create!(machine: machine_b, work_order: order_b, bucket_start: M0 - 600, bucket_end: M0 - 590,
                            good_qty: 10, defect_qty: 0, machine_version: 0)

    # 수요 품목 n=2, 기본 수요: A = 610 x 0.3 = 183, B = 10 x 0.3 = 3
    #   k=2 (둘 다 골림, 보정 2/2=1): A = 183 → 180, B = 3 → 0  → 줄 1개(A 180), B 줄은 필터로 빠진다
    #   k=1 (하나만 골림, 보정 2/1=2): A = 366 → 360 (줄 1개), B = 6 → 0 (줄 없음 → 수주 0)
    # 필터가 없으면 k=2 분에 B 의 ordered_qty 0 줄이 DB 체크 제약에 걸려 수주가 롤백되고(step 이 예외를 삼켜 수주 0),
    # 180 짜리 수주는 한 번도 나오지 않는다. 180 은 보정이 1일 때, 즉 두 품목이 함께 골렸을 때만 나오는 수량이다.
    both_picked = []
    (0..20).each do |m|
      SalesOrderLine.delete_all
      SalesOrder.delete_all
      run_minute(m)
      lines = SalesOrderLine.all.to_a
      next if lines.empty?

      assert_equal 1, SalesOrder.count, "분 #{m}"
      assert_equal [@fg.id], lines.map(&:product_id), "분 #{m}: 0 이 되는 B 는 줄이 없다"
      assert_includes [180, 360], lines.first.ordered_qty, "분 #{m}"
      both_picked << m if lines.first.ordered_qty == 180
    end
    puts "[3d6d2] 두 품목이 함께 골린 분: #{both_picked.inspect}" if ENV["VERBOSE_3D6D2"]
    assert_not_empty both_picked, "0..20분 중 두 품목이 함께 골린 분이 없으면 이 테스트는 필터를 지키지 못한다"
  end

  test "생산이 0 이면 수주도 0 이다" do
    assert_equal 0, run_minute(0)[:order]
    assert_equal 0, SalesOrder.count
  end

  test "진행 중 작업지시가 없으면 신규 수주도 없다" do
    @order.update!(status: "done")
    assert_equal 0, run_minute(0)[:order]
  end

  test "catch_up 이 터져도 신규 수주는 실행되고 실패는 로그 1줄이다" do
    produce_history(9000)
    original = Simulation::Logistics.instance_method(:catch_up)
    Simulation::Logistics.send(:define_method, :catch_up) { |*| raise "catch_up 실패" }
    begin
      result = run_minute(0)
    ensure
      Simulation::Logistics.send(:define_method, :catch_up, original)
    end

    assert_equal 1, result[:order]
    assert_equal 1, @log.string.lines.grep(/sim logistics backflush .*catch_up 실패/).size
  end

  test "한 단계의 PG 오류는 그 단계만 되돌리고 다음 단계는 정상이다" do
    produce_history(9000)
    original = Simulation::Logistics.instance_method(:catch_up)
    Simulation::Logistics.send(:define_method, :catch_up) do |*|
      Quant.insert_all([{ product_id: -1, location_id: -1, qty: 1 }]) # 없는 FK → PG 오류, 트랜잭션 aborted
    end
    begin
      result = run_minute(0)
    ensure
      Simulation::Logistics.send(:define_method, :catch_up, original)
    end

    assert_equal 1, result[:order], "뒤 단계는 aborted 트랜잭션에 걸리지 않는다"
    assert_equal 1, SalesOrder.count
    assert_equal 1, @log.string.lines.grep(/sim logistics backflush .*ForeignKey/).size
    assert_equal 1, @log.string.lines.grep(/ERROR/).size
  end

  test "이어서 돌려도 물리 위치가 마이너스가 되지 않고 Reconcile 이 0 이다" do
    ProductionEvent.create!(machine: @machine, work_order: @order, bucket_start: M0 - 600, bucket_end: M0 - 590,
                            good_qty: 90, defect_qty: 10, machine_version: 0)
    (0..4).each { |n| run_minute(n) }

    assert_equal 0, Quant.joins(:location).where(locations: { kind: "physical" }).where("quants.qty < 0").count
    assert_equal [], Inventory::Reconcile.call
  end
end
