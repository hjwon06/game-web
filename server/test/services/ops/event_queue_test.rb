require "test_helper"

class Ops::EventQueueTest < ActiveSupport::TestCase
  setup do
    Resource.ensure_defaults!
    Ops::Plan.reseed!(7)
    @product = Product.create!(sku: "RAW-OPS", name: "큐 강판", uom: "ea", kind: "raw")
    @fork1 = Resource.find_by!(code: "FORK-01")
    @fork2 = Resource.find_by!(code: "FORK-02")
    @bin = Location.find_by!(code: "RAW-A-01-01")
    @t0 = Time.current.change(usec: 0) + 1.hour
    @auto = 0
  end

  def stock_receiving(qty, key: "ops-recv")
    Inventory::Move.call(product: @product, lot: nil, from: "supplier", to: "receiving", qty: qty, move_type: "receive",
                         ref: nil, idempotency_key: key)
  end

  # 계획은 가용 재고를 다시 확인하므로 기본은 계획할 수량만큼 입고대에 먼저 채운다. stock: false 면 이미 있는 재고만 쓴다.
  def plan_putaway(qty: 10, to: @bin, earliest_at: @t0, stock: true)
    stock_receiving(qty, key: "ops-auto-#{@auto += 1}") if stock
    Ops::Plan.call(kind: "putaway", product: @product, lot: nil, qty: qty, from: "receiving", to: to, ref: nil,
                   earliest_at: earliest_at)
  end

  # 한 자원에 손으로 줄 세운다(완료 순서를 고정해야 하는 테스트용). 소요 45초씩.
  def queue_on(resource, qtys, to: @bin)
    qtys.each_with_index.map do |qty, i|
      at = @t0 + (i * 45).seconds
      Task.create!(kind: "putaway", resource: resource, product: @product, qty: qty, planned_at: at,
                   expected_finish_at: at + 45.seconds, from_location: Location.find_by!(code: "receiving"), to_location: to)
    end
  end

  def task_moves = StockMove.where("idempotency_key LIKE 'task:%'")

  # Tick 1회는 자원당 1건만 끝내므로(D2) 밀린 작업이 없어질 때까지 같은 시각으로 반복하고 결과를 합친다.
  def drain(now)
    total = Ops::Tick::Result.new(started: [], done: [], cancelled: [])
    10.times do
      r = Ops::Tick.call(now: now)
      total.started.concat(r.started)
      total.done.concat(r.done)
      total.cancelled.concat(r.cancelled)
      break if r.done.empty? && r.cancelled.empty?
    end
    total
  end

  test "지게차 2대에 putaway 5건: 시작 시각이 겹치지 않고 두 줄로 이어진다" do
    tasks = Array.new(5) { plan_putaway }

    by_resource = tasks.group_by(&:resource_id)
    assert_equal [@fork1.id, @fork2.id].sort, by_resource.keys.sort
    assert_operator by_resource.values.map(&:size).min, :>=, 2

    by_resource.each_value do |line|
      line = line.sort_by(&:planned_at)
      assert_equal @t0, line.first.planned_at
      line.each_cons(2) do |a, b|
        assert_operator b.planned_at, :>=, a.expected_finish_at, "겹침: #{a.id} → #{b.id}"
        assert_equal a.expected_finish_at, b.planned_at, "빈틈 없이 이어져야 한다"
      end
    end
  end

  test "earliest_at 이 자원이 비는 시각보다 늦으면 earliest_at 에 시작한다" do
    first = plan_putaway
    late = plan_putaway(earliest_at: first.expected_finish_at + 10.minutes)
    assert_equal first.expected_finish_at + 10.minutes, late.planned_at
  end

  test "kind 마다 맞는 자원 종류를 고른다" do
    # 출발지가 물리 위치인 kind 는 계획이 가용 재고를 확인하므로 각 출발지에 재고를 만들어 둔다(Ops 를 거치지 않는다).
    %w[shipping qc fg_store raw_store].each do |code|
      Quant.create!(product: @product, lot: nil, location: Location.find_by!(code: code), qty: 5)
    end
    {
      "unload" => ["dock_in", "supplier", "receiving"], "load" => ["dock_out", "shipping", "customer"],
      "inspect" => ["worker", "qc", "fg_store"], "pick" => ["forklift", "fg_store", "shipping"],
      "feed" => ["forklift", "raw_store", "line_side"]
    }.each do |kind, (res_kind, from, to)|
      t = Ops::Plan.call(kind: kind, product: @product, lot: nil, qty: 1, from: from, to: to, ref: nil, earliest_at: @t0)
      assert_equal res_kind, t.resource.kind, kind
    end
  end

  test "같은 시드면 소요시간이 같고, 시드가 다르면 달라진다. 범위는 기본값의 0.8~1.2배" do
    durations = lambda do |seed|
      Ops::Plan.reseed!(seed)
      Array.new(6) { |i| plan_putaway(earliest_at: @t0 + (i * 1000).seconds) }.map { |t| (t.expected_finish_at - t.planned_at).round(3) }
    end

    a = durations.call(42)
    b = durations.call(42)
    c = durations.call(43)
    assert_equal a, b
    assert_not_equal a, c
    assert(a.all? { |d| d >= 45 * 0.8 - 0.001 && d <= 45 * 1.2 + 0.001 }, a.inspect)
  end

  test "Tick 을 시각을 옮겨가며 부르면 완료마다 stock_moves 1건이고 다시 불러도 늘지 않는다" do
    stock_receiving(500)
    tasks = Array.new(4) { plan_putaway(qty: 50) }
    base = StockMove.count

    Ops::Tick.call(now: @t0 - 1.second)
    assert_equal 0, Task.where(id: tasks.map(&:id), status: "started").count
    assert_equal base, StockMove.count

    r = Ops::Tick.call(now: @t0)
    assert_equal 2, r.started.size # 지게차 2대 = 동시에 둘
    assert_equal base, StockMove.count, "시작은 재고를 움직이지 않는다"

    done_so_far = 0
    tasks.map(&:expected_finish_at).uniq.sort.each do |t|
      Ops::Tick.call(now: t)
      done_now = Task.where(id: tasks.map(&:id), status: "done").count
      assert_operator done_now, :>, done_so_far
      done_so_far = done_now
      assert_equal done_now, task_moves.count, "완료 1건당 이동 1건"
      Ops::Tick.call(now: t) # 같은 시각 재실행
      assert_equal done_now, task_moves.count
    end

    assert_equal 4, done_so_far
    assert_equal base + 4, StockMove.count
    assert_equal 200, Quant.where(location_id: @bin.id).sum(:qty)
    done = Task.where(id: tasks.map(&:id)).includes(:stock_move)
    assert_equal tasks.map { |t| "task:#{t.id}" }.sort, done.map { |t| t.stock_move.idempotency_key }.sort
    assert_equal [], Inventory::Reconcile.call
  end

  test "D2: 오래 멈췄다 재개돼도 Tick 1회에 자원당 1건만 끝내고 나머지는 다음 Tick 이 이어서 한다" do
    stock_receiving(100)
    a, b, c = queue_on(@fork1, [10, 20, 30])
    d = queue_on(@fork2, [5]).first
    base = StockMove.count

    r = Ops::Tick.call(now: @t0 + 30.minutes) # 30분 멈췄다 재개: 밀린 작업이 4건
    assert_equal [a.id, d.id].sort, r.done.sort, "자원 2대 = 완료 2건 이하"
    assert_operator r.done.size, :<=, Resource.where(kind: "forklift").count
    assert_equal base + 2, StockMove.count
    assert_equal "started", b.reload.status, "다음 작업은 시작만 했다"
    assert_equal "planned", c.reload.status
    assert_equal @t0, a.reload.started_at
    assert_equal a.expected_finish_at, b.started_at

    r2 = Ops::Tick.call(now: @t0 + 30.minutes)
    assert_equal [b.id], r2.done
    assert_equal [c.id], Ops::Tick.call(now: @t0 + 30.minutes).done
    assert_equal %w[done done done], [a, b, c].map { |t| t.reload.status }
    assert_equal base + 4, StockMove.count
  end

  test "한 자원은 started 가 동시에 하나뿐이다: 시작 시각이 겹치게 만든 두 건 중 하나만 시작한다" do
    a = Task.create!(kind: "putaway", resource: @fork1, product: @product, qty: 1, planned_at: @t0,
                     expected_finish_at: @t0 + 60.seconds, from_location: Location.find_by!(code: "receiving"), to_location: @bin)
    b = Task.create!(kind: "putaway", resource: @fork1, product: @product, qty: 1, planned_at: @t0 + 10.seconds,
                     expected_finish_at: @t0 + 70.seconds, from_location: Location.find_by!(code: "receiving"), to_location: @bin)

    r = Ops::Tick.call(now: @t0 + 30.seconds)
    assert_equal [a.id], r.started
    assert_equal "planned", b.reload.status
    assert_equal 1, Task.where(resource_id: @fork1.id, status: "started").count
  end

  test "상태가 바뀔 때마다 seq 가 새로 배정된다" do
    stock_receiving(10)
    t = plan_putaway(qty: 10)
    s0 = t.reload.seq
    Ops::Tick.call(now: @t0)
    s1 = t.reload.seq
    Ops::Tick.call(now: t.expected_finish_at)
    s2 = t.reload.seq
    assert_operator s0, :<, s1
    assert_operator s1, :<, s2
  end

  test "재고 부족으로 완료가 실패하면 그 작업만 cancelled 이고 다음 작업은 계속된다" do
    stock_receiving(150)
    ok1, short, ok2 = queue_on(@fork1, [100, 100, 40])
    base = StockMove.count

    r = drain(@t0 + 1.hour)

    assert_equal [ok1.id, ok2.id], r.done
    assert_equal [short.id], r.cancelled
    assert_equal %w[done cancelled done], [ok1, short, ok2].map { |t| t.reload.status }
    assert_match(/InsufficientStock/, short.cancel_reason)
    assert_nil short.stock_move_id
    assert_equal base + 2, StockMove.count
    assert_equal 140, Quant.where(location_id: @bin.id).sum(:qty)
    assert_equal [], Inventory::Reconcile.call
  end

  test "Plan 이 만든 작업의 예약은 완료 때 consumed, 취소 때 released 이고 다른 작업의 예약은 그대로다" do
    stock_receiving(100)
    short = plan_putaway(qty: 60, stock: false) # 먼저 끝나려는 작업. 아래에서 재고가 모자라게 되어 이쪽이 취소된다
    ok = plan_putaway(qty: 35, stock: false)
    still = plan_putaway(qty: 5, earliest_at: @t0 + 1.day, stock: false)
    assert_equal %w[active active active], Reservation.order(:task_id).pluck(:status)
    assert_equal [@fork1.id, @fork2.id], [short.resource_id, ok.resource_id], "Tick 이 자원 id 순이라 short 가 먼저 끝난다"
    # 계획을 통과한 뒤 입고대 재고 20 이 장부 밖에서 줄었다(수량만 직접 깎는다 — 8b K1 이 예약 밖 이동은 막는다).
    # 예약 합 100 > 재고 80 이라 먼저 끝나려는 short(60)는 가용(80 - 다른 작업 예약 40)이 모자라 취소되고,
    # 그 예약이 풀린 뒤 ok(35)는 가용(80 - 5)이 충분해 끝난다.
    Quant.where(product: @product, location: Location.find_by!(code: "receiving")).update_all("qty = qty - 20")

    r = drain(@t0 + 1.hour)

    assert_equal [ok.id], r.done
    assert_equal [short.id], r.cancelled
    by_task = Reservation.pluck(:task_id, :status).to_h
    assert_equal({ ok.id => "consumed", short.id => "released", still.id => "active" }, by_task)
  end

  test "칸 용량을 넘겨서 완료가 실패해도 그 작업만 cancelled 이다" do
    cap = Location::BIN_CAPACITY
    stock_receiving(2 * cap)
    ok1, over, ok2 = queue_on(@fork1, [cap - 100, cap - 100, 50])

    r = drain(@t0 + 1.hour)

    assert_equal [over.id], r.cancelled
    assert_equal %w[done cancelled done], [ok1, over, ok2].map { |t| t.reload.status }
    assert_match(/CapacityExceeded/, over.cancel_reason)
    assert_equal cap - 50, Quant.where(location_id: @bin.id).sum(:qty)
  end

  test "취소된 작업은 Tick 을 다시 불러도 되살아나지 않고 이동도 안 생긴다" do
    stock_receiving(10)
    _ok, short = queue_on(@fork1, [10, 10])
    drain(@t0 + 1.hour)
    count = StockMove.count
    drain(@t0 + 2.hours)
    assert_equal "cancelled", short.reload.status
    assert_equal count, StockMove.count
  end

  # 종류별 완료 이동. 작업은 손으로 만들고(자원 @fork1) 한 번의 Tick 으로 끝낸다.
  def finish_one(kind, from:, to:, qty: 10, lot: nil, ref: nil, resource: @fork1)
    task = Task.create!(kind: kind, resource: resource, product: @product, lot: lot, qty: qty, planned_at: @t0,
                        expected_finish_at: @t0 + 40.seconds, from_location: Location.find_by!(code: from),
                        to_location: Location.find_by!(code: to), ref_type: ref&.class&.name, ref_id: ref&.id)
    Ops::Tick.call(now: @t0 + 1.minute)
    task.reload
  end

  def stock_at(code, qty, lot: nil, key: "ops-stock")
    Inventory::Move.call(product: @product, lot: lot, from: "supplier", to: "receiving", qty: qty, move_type: "receive",
                         ref: nil, idempotency_key: "#{key}-r")
    Inventory::Move.call(product: @product, lot: lot, from: "receiving", to: "RAW-A-01-01", qty: qty, move_type: "putaway",
                         ref: nil, idempotency_key: "#{key}-p")
    return if code == "RAW-A-01-01"

    Inventory::Move.call(product: @product, lot: lot, from: "RAW-A-01-01", to: code, qty: qty, move_type: "feed",
                         ref: nil, idempotency_key: "#{key}-f")
  end

  test "feed 완료는 raw 칸 → line_side 의 feed 이동 1건이다" do
    stock_at("RAW-A-01-01", 50)

    task = finish_one("feed", from: "RAW-A-01-01", to: "line_side", qty: 30)

    assert_equal "done", task.status
    assert_equal ["feed", "task:#{task.id}"], [task.stock_move.move_type, task.stock_move.idempotency_key]
    assert_equal [20, 30], [Quant.where(location: @bin, product: @product).sum(:qty), Quant.where(location: Location.find_by!(code: "line_side")).sum(:qty)]
  end

  test "raw 칸 → production 직접 issue 는 경로 오류다(line_side 를 거쳐야 한다)" do
    stock_at("RAW-A-01-01", 50)
    assert_raises(Inventory::Move::InvalidPath) do
      Inventory::Move.call(product: @product, lot: nil, from: @bin, to: "production", qty: 1, move_type: "issue", ref: nil,
                           idempotency_key: "ops-direct-issue")
    end
  end

  test "pick 완료는 fg 칸 → shipping 의 pick 이동 1건이다" do
    lot = Lot.create!(product: @product, lot_no: "LOT-OPS-PICK")
    Inventory::Move.call(product: @product, lot: lot, from: "production", to: "qc", qty: 40, move_type: "produce", ref: nil, idempotency_key: "ops-pk-1")
    Inventory::Move.call(product: @product, lot: lot, from: "qc", to: "FG-A-01-01", qty: 40, move_type: "qc_pass", ref: nil, idempotency_key: "ops-pk-2")

    task = finish_one("pick", from: "FG-A-01-01", to: "shipping", qty: 25, lot: lot)

    assert_equal "done", task.status
    assert_equal ["pick", "FG-A-01-01", "shipping"], [task.stock_move.move_type, task.stock_move.from_location.code, task.stock_move.to_location.code]
    assert_equal 25, Quant.where(location: Location.find_by!(code: "shipping"), product: @product).sum(:qty)
    assert_equal [], Inventory::Reconcile.call
  end

  test "putaway 가 qc 에서 나가면 qc_pass 이동이고, 입고대에서 나가면 putaway 이동이다" do
    lot = Lot.create!(product: @product, lot_no: "LOT-OPS-QP")
    Inventory::Move.call(product: @product, lot: lot, from: "production", to: "qc", qty: 40, move_type: "produce", ref: nil, idempotency_key: "ops-qp-1")
    stock_receiving(10, key: "ops-qp-recv")

    pass = finish_one("putaway", from: "qc", to: "FG-A-01-02", qty: 40, lot: lot)
    put = finish_one("putaway", from: "receiving", to: "RAW-A-01-01", qty: 10, resource: @fork2)

    assert_equal %w[qc_pass putaway], [pass.stock_move.move_type, put.stock_move.move_type]
    assert_equal [], Inventory::Reconcile.call
  end

  test "load 완료는 수주 라인이 있으면 Inventory::Ship 으로 출하량과 수주 상태까지 갱신한다" do
    fg = Product.create!(sku: "FG-OPS", name: "큐 완제품", uom: "ea", kind: "fg")
    lot = Lot.create!(product: fg, lot_no: "LOT-OPS-LD")
    [["production", "qc", "produce"], ["qc", "FG-A-01-01", "qc_pass"], ["FG-A-01-01", "shipping", "pick"]].each_with_index do |(from, to, type), i|
      Inventory::Move.call(product: fg, lot: lot, from: from, to: to, qty: 10, move_type: type, ref: nil, idempotency_key: "ops-ld-#{i}")
    end
    line = SalesOrder.create!(so_no: "SO-OPS", customer: "큐고객").lines.create!(product: fg, ordered_qty: 10)
    task = Task.create!(kind: "load", resource: Resource.find_by!(code: "DOCK-OUT-01"), product: fg, lot: lot, qty: 10, planned_at: @t0,
                        expected_finish_at: @t0 + 40.seconds, from_location: Location.find_by!(code: "shipping"),
                        to_location: Location.find_by!(code: "customer"), ref_type: "SalesOrderLine", ref_id: line.id)

    Ops::Tick.call(now: @t0 + 1.minute)

    assert_equal "done", task.reload.status
    assert_equal ["ship", "SalesOrderLine", line.id], [task.stock_move.move_type, task.stock_move.ref_type, task.stock_move.ref_id]
    assert_equal "done", line.sales_order.reload.status
    assert_equal [], Inventory::Reconcile.call
  end

  test "주문량을 넘기는 load 는 OverShipment 로 그 작업만 취소된다" do
    fg = Product.create!(sku: "FG-OPS2", name: "큐 완제품2", uom: "ea", kind: "fg")
    lot = Lot.create!(product: fg, lot_no: "LOT-OPS-OV")
    [["production", "qc", "produce"], ["qc", "FG-A-01-01", "qc_pass"], ["FG-A-01-01", "shipping", "pick"]].each_with_index do |(from, to, type), i|
      Inventory::Move.call(product: fg, lot: lot, from: from, to: to, qty: 20, move_type: type, ref: nil, idempotency_key: "ops-ov-#{i}")
    end
    line = SalesOrder.create!(so_no: "SO-OPS2", customer: "큐고객").lines.create!(product: fg, ordered_qty: 10)
    task = Task.create!(kind: "load", resource: Resource.find_by!(code: "DOCK-OUT-01"), product: fg, lot: lot, qty: 20, planned_at: @t0,
                        expected_finish_at: @t0 + 40.seconds, from_location: Location.find_by!(code: "shipping"),
                        to_location: Location.find_by!(code: "customer"), ref_type: "SalesOrderLine", ref_id: line.id)

    Ops::Tick.call(now: @t0 + 1.minute)

    assert_equal "cancelled", task.reload.status
    assert_match(/OverShipment/, task.cancel_reason)
    assert_equal 0, StockMove.where(move_type: "ship").count
  end

  test "inspect 는 작업지시가 없으면 이동 없이 done 이다" do
    base = StockMove.count

    task = finish_one("inspect", from: "qc", to: "fg_store", resource: Resource.find_by!(code: "WORKER-01"))

    assert_equal "done", task.status
    assert_nil task.stock_move
    assert_equal base, StockMove.count
  end
end
