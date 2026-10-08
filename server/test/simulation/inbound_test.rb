require "test_helper"
require "stringio"

# 입고: 트럭 도착 → 팔레트별 하차(unload) → 칸 적치(putaway). 시계는 테스트가 10초씩 직접 흘린다.
class InboundTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 10, 8, 12, 7, 30)
  P = Simulation::Config::PALLET_QTY # 팔레트 1개

  setup do
    Resource.ensure_defaults!
    Ops::Plan.reseed!(11)
    @steel = Product.create!(sku: "RAW-S", name: "강판", uom: "ea", kind: "raw")
    @bolt = Product.create!(sku: "RAW-B", name: "볼트", uom: "ea", kind: "raw")
    @fg = Product.create!(sku: "FG-BR", name: "브래킷", uom: "ea", kind: "fg")
    BomLine.create!(product: @fg, component: @steel, qty_per: 2) # M1 양품 0.784/s → 30분 강판 2822.4, 볼트 1411.2
    BomLine.create!(product: @fg, component: @bolt, qty_per: 1)
    @machine = Machine.create!(code: "M1", name: "절단기", state: "running")
    WorkOrder.create!(code: "WO-I1", machine: @machine, item: @fg, product: "브래킷", target_qty: 100_000,
                      status: "active", started_at: NOW)
    @log = StringIO.new
    @seq = 0
  end

  def inbound(now) = Simulation::Inbound.call(now: now, logger: Logger.new(@log))

  # 다음 트럭을 지금 도착하게 한다.
  def due!(at, scheduled: at - 1)
    InboundState.delete_all
    InboundState.create!(next_truck_at: scheduled)
  end

  def roomy_bins!
    Location.where(id: Simulation::Inbound.bins_under("raw_store").select(:id)).update_all(capacity_units: 1_000_000)
  end

  def next_key = "inbound-test-#{@seq += 1}"

  # 칸에 재고를 만든다(Ops 를 거치지 않는다).
  def seed_bin(product, code, qty)
    Inventory::Move.call(product: product, lot: nil, from: "supplier", to: "receiving", qty: qty, move_type: "receive",
                         ref: nil, idempotency_key: next_key)
    Inventory::Move.call(product: product, lot: nil, from: "receiving", to: code, qty: qty, move_type: "putaway",
                         ref: nil, idempotency_key: next_key)
  end

  # 하차가 끝난 팔레트 1개(적치 대기).
  def done_unload(product, finished_at)
    lot = Lot.find_or_create_by!(product: product, lot_no: "R-T-#{product.sku}")
    Task.create!(kind: "unload", status: "done", resource: Resource.find_by!(code: "DOCK-IN-01"), product: product, lot: lot,
                 qty: P, from_location: Location.find_by!(code: "supplier"), to_location: Location.find_by!(code: "receiving"),
                 planned_at: finished_at - 100, started_at: finished_at - 100, expected_finish_at: finished_at, finished_at: finished_at)
  end

  def putaways = Task.where(kind: "putaway").order(:id)

  def truck_lots = Lot.where("lot_no LIKE 'R-2%'").order(:id)

  # from 부터 seconds 만큼 10초씩 Ops::Tick → Inbound. 다음 트럭 예정 시각이 바뀔 때마다 [호출 시각, 새 예정 시각] 을 @schedule 에 쌓는다.
  def drive(from, seconds)
    @schedule ||= []
    (seconds / 10).times do |i|
      now = from + ((i + 1) * 10)
      Ops::Tick.call(now: now)
      inbound(now)
      scheduled = InboundState.pick(:next_truck_at)
      @schedule << [now, scheduled] if @schedule.empty? || @schedule.last[1] != scheduled
    end
    from + seconds
  end

  test "시계를 흘리면 트럭 간격은 4~8분이고 예정 시각에서 10초 안에 도착한다" do
    drive(Time.current.change(usec: 0), 3600)

    schedule = @schedule.map(&:last)
    assert_operator schedule.size, :>=, 7, "한 시간에 예정이 7번 이상 바뀐다(간격 최대 8분)"
    schedule.each_cons(2) { |a, b| assert_includes 240..480, b - a, "간격 #{b - a}초" }
    @schedule.each_cons(2) do |(_, prev), (called, _)|
      assert_operator called - prev, :>=, 0
      assert_operator called - prev, :<, 10, "예정 #{prev} 인데 #{called} 에 도착"
    end
    # 팔레트가 500개라 트럭 한 대가 30분 소비량(강판 2822·볼트 1411)을 거의 채운다. 소비가 없는 이 테스트에서는 자재마다 한두 대면 끝난다.
    assert_operator truck_lots.count, :>=, 2
  end

  test "팔레트마다 unload 1건·putaway 1건이고, 이동 시각이 서로 달라 같은 초에 2건 이하다" do
    t = drive(Time.current.change(usec: 0), 3600)
    @machine.update!(state: "stopped") # 소비 예상이 0 이 되어 새 트럭이 없다
    drive(t, 1200) # 남은 하차·적치가 끝날 때까지

    unloads = Task.where(kind: "unload").order(:id).to_a
    assert_operator unloads.size, :>=, 8
    assert unloads.all? { |u| u.status == "done" }, "하차가 전부 끝났다"
    unloads.group_by(&:lot_id).each_value { |list| assert_includes 4..8, list.size, "트럭당 팔레트 4~8개" }
    assert_equal unloads.map(&:lot_id).uniq.size, truck_lots.count, "트럭 1대 = 로트 1개"
    assert unloads.all? { |u| u.qty == P && u.from_location.code == "supplier" && u.to_location.code == "receiving" }

    assert_equal unloads.map(&:id).sort, putaways.map(&:ref_id).sort, "팔레트마다 putaway 정확히 1건"
    assert putaways.all? { |p| p.status == "done" && p.ref_type == "Task" && p.qty == P && p.from_location.code == "receiving" }
    done_at = unloads.to_h { |u| [u.id, u.finished_at] }
    assert putaways.all? { |p| p.planned_at >= done_at.fetch(p.ref_id) }, "putaway 는 그 팔레트 하차가 끝난 뒤에 시작한다"

    [unloads, putaways.to_a].each do |tasks|
      assert_operator tasks.group_by { |task| task.finished_at.to_i }.values.map(&:size).max, :<=, 2, "같은 초 완료 2건 이하"
    end
    assert_operator unloads.group_by { |u| u.finished_at.to_i / 60 }.values.map(&:size).max, :<=, 2, "도크 2대: 분당 하차 2건 이하"
    assert_operator putaways.to_a.group_by { |p| p.finished_at.to_i / 60 }.values.map(&:size).max, :<=, 4, "지게차 2대: 분당 적치 4건 이하"

    assert_equal unloads.size, StockMove.where(move_type: "receive").count
    assert_equal unloads.size, StockMove.where(move_type: "putaway").count
    assert_equal 0, Quant.joins(:location).where(locations: { code: "receiving" }).sum(:qty), "입고대는 비었다"
    bins = Simulation::Inbound.bins_under("raw_store").pluck(:id)
    assert_equal unloads.size * P, Quant.where(location_id: bins).sum(:qty)
    assert_equal [], Inventory::Reconcile.call
    assert_equal 0, @log.string.lines.grep(/ERROR/).size
  end

  test "로트는 R-yyyymmddHHMM-sku 로 트럭당 1개이고, 팔레트는 4~8개다" do
    due!(NOW)

    result = inbound(NOW)

    assert_equal 1, result[:trucks]
    assert_includes 4..8, result[:unload]
    assert_equal ["R-202610081207-RAW-S"], truck_lots.pluck(:lot_no), "아무 재고도 없으면 30분 소비가 가장 큰 강판이다"
    tasks = Task.where(kind: "unload")
    assert_equal result[:unload], tasks.count
    assert_equal [truck_lots.first.id], tasks.pluck(:lot_id).uniq
    assert tasks.all? { |t| t.status == "planned" && t.qty == P }
  end

  test "칸 고르기 ①: 같은 품목이고 남은 용량이 팔레트 이상인 칸 중 코드 순 첫 칸, ②: 없으면 빈 칸 중 코드 순 첫 칸" do
    seed_bin(@steel, "RAW-A-01-01", Location::BIN_CAPACITY - (P / 2)) # 같은 품목이지만 남은 용량이 팔레트의 절반
    seed_bin(@bolt, "RAW-A-01-02", P)  # 다른 품목
    seed_bin(@steel, "RAW-A-01-03", Location::BIN_CAPACITY - (2 * P)) # 같은 품목, 남은 용량 팔레트 2개
    4.times { |i| done_unload(@steel, NOW - 50 + (i * 10)) }

    result = inbound(NOW)

    assert_equal 4, result[:putaway]
    # 03: 팔레트 2개가 들어가 가득 → 빈 칸 04 → 04 에 강판이 생겼으니 ① 로 04
    assert_equal %w[RAW-A-01-03 RAW-A-01-03 RAW-A-01-04 RAW-A-01-04], putaways.map { |p| p.to_location.code }
  end

  test "칸 고르기: 이미 계획된 적치도 칸 용량과 품목으로 센다(다른 품목은 그 칸을 못 쓴다)" do
    done_unload(@steel, NOW - 20)
    other = done_unload(@bolt, NOW - 10)
    inbound(NOW)

    codes = putaways.includes(:to_location).to_h { |p| [p.ref_id, p.to_location.code] }
    assert_equal "RAW-A-01-01", codes.fetch(Task.where(kind: "unload", product_id: @steel.id).pick(:id))
    assert_equal "RAW-A-01-02", codes.fetch(other.id), "01 칸은 계획된 강판이 차지했으니 볼트는 다음 빈 칸"
  end

  test "칸 고르기 ③: 칸이 없으면 계획하지 않고 로그를 남기며, 칸이 비면 다음 호출에 적치한다" do
    Simulation::Inbound.bins_under("raw_store").pluck(:code).each { |code| seed_bin(@bolt, code, P) } # 전부 다른 품목이 점유
    done_unload(@steel, NOW - 10)

    result = inbound(NOW)

    assert_equal [0, 1], [result[:putaway], result[:waiting]]
    assert_equal 0, putaways.count
    assert_match(/적치할 칸이 없어 receiving 에 1팔레트 대기/, @log.string)

    # 칸을 비우는 길은 feed(raw 칸 → line_side)다. line_side 는 칸 고르기 대상이 아니라 비어 있어도 고르지 않는다.
    Inventory::Move.call(product: @bolt, lot: nil, from: "RAW-A-01-05", to: "line_side", qty: P, move_type: "feed",
                         ref: nil, idempotency_key: next_key)
    again = inbound(NOW + 10)

    assert_equal [1, 0], [again[:putaway], again[:waiting]]
    assert_equal ["RAW-A-01-05"], putaways.map { |p| p.to_location.code }
    assert_equal "raw_store", putaways.last.to_location.zone_code
  end

  test "취소된 적치는 다시 계획하되 3번 취소되면 포기한다" do
    done_unload(@steel, NOW - 10)

    4.times do |i|
      inbound(NOW + (i * 10))
      last = putaways.last
      last.update!(status: "cancelled", cancel_reason: "test") if last.status == "planned"
    end

    assert_equal 3, putaways.count
    assert_equal ["cancelled"] * 3, putaways.pluck(:status)
  end

  test "재시작해도(상태는 DB, 새 인스턴스) 같은 트럭이 두 번 오지 않는다" do
    due!(NOW)
    first = inbound(NOW)
    scheduled_after = InboundState.pick(:next_truck_at)

    repeats = [inbound(NOW), inbound(NOW + 10), inbound(NOW + 20)]

    assert_equal 1, first[:trucks]
    assert_equal [0, 0, 0], repeats.map { |r| r[:trucks] }
    assert_equal 1, truck_lots.count
    assert_equal first[:unload], Task.where(kind: "unload").count
    assert_equal scheduled_after, InboundState.pick(:next_truck_at)
    assert_equal 1, InboundState.count
    assert_includes 240..480, scheduled_after - (NOW - 1)
  end

  test "상태 행이 없으면 첫 호출이 만들고 트럭은 간격 뒤에 온다" do
    assert_equal 0, InboundState.count

    result = inbound(NOW)

    assert_equal 0, result[:trucks]
    assert_equal 1, InboundState.count
    assert_includes 240..480, InboundState.pick(:next_truck_at) - NOW
  end

  test "오래 멈췄다 돌아와도 트럭은 1대만 오고 다음 도착은 지금 + 간격이다" do
    due!(NOW, scheduled: NOW - 1.day)

    result = inbound(NOW)

    assert_equal 1, result[:trucks]
    assert_includes 240..480, InboundState.pick(:next_truck_at) - NOW
    assert_equal 0, inbound(NOW + 10)[:trucks]
  end

  test "부족한 자재가 없으면 트럭이 오지 않고 다음 시각만 잡는다" do
    roomy_bins!
    seed_bin(@steel, "RAW-A-01-01", 3000) # 2822.4 이상
    seed_bin(@bolt, "RAW-A-01-02", 1500)  # 1411.2 이상
    due!(NOW)

    result = inbound(NOW)

    assert_equal 0, result[:trucks]
    assert_equal 0, Task.count
    assert_equal 0, truck_lots.count
    assert_operator InboundState.pick(:next_truck_at), :>, NOW
  end

  test "소비가 없으면(기계 정지) 트럭이 오지 않는다" do
    @machine.update!(state: "stopped")
    due!(NOW)

    assert_equal 0, inbound(NOW)[:trucks]
    assert_equal 0, Task.count
  end

  test "가장 모자란 자재를 싣는다: 다른 자재가 더 부족하면 그쪽이다" do
    roomy_bins!
    seed_bin(@steel, "RAW-A-01-01", 2800) # 부족 22.4, 볼트는 1411.2
    due!(NOW)

    inbound(NOW)

    assert_equal ["R-202610081207-RAW-B"], truck_lots.pluck(:lot_no)
  end

  test "line_side 에 있는 재고도 센다: line_side 가 넉넉한 자재는 raw 칸이 비어도 건너뛴다" do
    roomy_bins!
    seed_bin(@steel, "RAW-A-01-01", 3000)
    Inventory::Move.call(product: @steel, lot: nil, from: "RAW-A-01-01", to: "line_side", qty: 3000, move_type: "feed",
                         ref: nil, idempotency_key: next_key) # raw 칸 0, line_side 3000(필요 2822.4 이상)
    due!(NOW)

    inbound(NOW)

    assert_equal ["R-202610081207-RAW-B"], truck_lots.pluck(:lot_no)
  end

  test "이미 계획된 하차분도 입고 예정으로 센다" do
    roomy_bins!
    seed_bin(@steel, "RAW-A-01-01", 2800) # 부족 22.4
    Task.create!(kind: "unload", status: "planned", product: @bolt, qty: 1400, planned_at: NOW + 60, from_location: Location.find_by!(code: "supplier"),
                 to_location: Location.find_by!(code: "receiving")) # 볼트 부족 11.2
    due!(NOW)

    inbound(NOW)

    assert_equal ["R-202610081207-RAW-S"], truck_lots.pluck(:lot_no)
  end

  test "자원이 없어 계획이 실패하면 트럭 전체가 롤백되고 예외 없이 로그만 남으며, 자원이 생기면 다음 호출에 온다" do
    Resource.delete_all
    due!(NOW)

    result = inbound(NOW)

    assert_equal 0, result[:trucks]
    assert_equal 0, Task.count
    assert_equal 0, truck_lots.count, "로트도 같이 롤백된다"
    assert_operator InboundState.pick(:next_truck_at), :<=, NOW, "아직 도착 전으로 남는다"
    assert_equal 1, @log.string.lines.grep(/sim inbound truck .*NoResource/).size

    Resource.ensure_defaults!
    assert_equal 1, inbound(NOW + 10)[:trucks]
  end

  test "적치 단계가 실패해도 같은 호출의 트럭은 온다" do
    done_unload(@steel, NOW - 10)
    due!(NOW)
    original = Simulation::Inbound.instance_method(:plan_putaways)
    Simulation::Inbound.send(:define_method, :plan_putaways) { raise "적치 실패" }
    begin
      result = inbound(NOW)
    ensure
      Simulation::Inbound.send(:define_method, :plan_putaways, original)
    end

    assert_equal 1, result[:trucks]
    assert_equal 1, @log.string.lines.grep(/sim inbound putaway .*적치 실패/).size
  end
end
