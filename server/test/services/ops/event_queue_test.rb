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
  end

  def stock_receiving(qty, key: "ops-recv")
    Inventory::Move.call(product: @product, lot: nil, from: "supplier", to: "receiving", qty: qty, move_type: "receive",
                         ref: nil, idempotency_key: key)
  end

  def plan_putaway(qty: 10, to: @bin, earliest_at: @t0)
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
    {
      "unload" => ["dock_in", "supplier", "receiving"], "load" => ["dock_out", "fg_store", "customer"],
      "inspect" => ["worker", "qc", "fg_store"], "pick" => ["forklift", "fg_store", "shipping"]
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

  test "한 번의 Tick 이 여러 건을 이어서 처리한다 (시작 → 완료 → 다음 시작 → 완료)" do
    stock_receiving(100)
    a, b = queue_on(@fork1, [10, 20])

    r = Ops::Tick.call(now: @t0 + 1.hour)
    assert_equal [a.id, b.id], r.done
    assert_equal %w[done done], [a, b].map { |t| t.reload.status }
    assert_equal @t0, a.started_at
    assert_equal a.expected_finish_at, b.reload.started_at
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

    r = Ops::Tick.call(now: @t0 + 1.hour)

    assert_equal [ok1.id, ok2.id], r.done
    assert_equal [short.id], r.cancelled
    assert_equal %w[done cancelled done], [ok1, short, ok2].map { |t| t.reload.status }
    assert_match(/InsufficientStock/, short.cancel_reason)
    assert_nil short.stock_move_id
    assert_equal base + 2, StockMove.count
    assert_equal 140, Quant.where(location_id: @bin.id).sum(:qty)
    assert_equal [], Inventory::Reconcile.call
  end

  test "칸 용량을 넘겨서 완료가 실패해도 그 작업만 cancelled 이다" do
    stock_receiving(1000)
    ok1, over, ok2 = queue_on(@fork1, [300, 300, 50]) # 칸 용량 400

    r = Ops::Tick.call(now: @t0 + 1.hour)

    assert_equal [over.id], r.cancelled
    assert_equal %w[done cancelled done], [ok1, over, ok2].map { |t| t.reload.status }
    assert_match(/CapacityExceeded/, over.cancel_reason)
    assert_equal 350, Quant.where(location_id: @bin.id).sum(:qty)
  end

  test "취소된 작업은 Tick 을 다시 불러도 되살아나지 않고 이동도 안 생긴다" do
    stock_receiving(10)
    _ok, short = queue_on(@fork1, [10, 10])
    Ops::Tick.call(now: @t0 + 1.hour)
    count = StockMove.count
    Ops::Tick.call(now: @t0 + 2.hours)
    assert_equal "cancelled", short.reload.status
    assert_equal count, StockMove.count
  end

  test "pick·inspect 의 재고 이동은 아직 정해지지 않았다고 명시적으로 알린다" do
    pick = Task.create!(kind: "pick", resource: @fork1, product: @product, qty: 1, planned_at: @t0,
                        expected_finish_at: @t0 + 40.seconds, from_location: Location.find_by!(code: "fg_store"),
                        to_location: Location.find_by!(code: "shipping"))
    base = StockMove.count
    assert_raises(Ops::Tick::NotImplemented) { Ops::Tick.call(now: @t0 + 1.minute) }
    assert_equal base, StockMove.count
    assert_not_equal "done", pick.reload.status
  end
end
