require "test_helper"
require "stringio"

# 입고: 발주(PO) → 리드타임 뒤 트럭 도착 → 팔레트별 하차(unload) → 칸 적치(putaway) → 발주 입고 완료. 시계는 테스트가 10초씩 직접 흘린다.
class InboundTest < ActiveSupport::TestCase
  include UnscaledRatesHelper
  include UnlimitedForkliftQueueHelper
  NOW = Time.utc(2026, 10, 8, 12, 7, 30)
  P = Simulation::Config::PALLET_QTY # 팔레트 1개

  setup do
    Resource.ensure_defaults!
    Ops::Plan.reseed!(11)
    @steel = Product.create!(sku: "RAW-S", name: "강판", uom: "ea", kind: "raw")
    @bolt = Product.create!(sku: "RAW-B", name: "볼트", uom: "ea", kind: "raw")
    @fg = Product.create!(sku: "FG-BR", name: "브래킷", uom: "ea", kind: "fg")
    # 적치 규칙: 기본은 자재창고 전체를 공용으로 연다(칸은 코드 순). 전용 랙·공용 랙 규칙은 rules! 로 바꿔서 확인한다.
    PutawayRule.create!(product: nil, location: Location.find_by!(code: "raw_store"), priority: 100)
    BomLine.create!(product: @fg, component: @steel, qty_per: 2) # M1 양품 0.784/s → 30분 강판 2822.4, 볼트 1411.2
    BomLine.create!(product: @fg, component: @bolt, qty_per: 1)
    @machine = Machine.create!(code: "M1", name: "절단기", state: "running")
    WorkOrder.create!(code: "WO-I1", machine: @machine, item: @fg, product: "브래킷", target_qty: 100_000,
                      status: "active", started_at: NOW)
    @steel_supplier = Supplier.create!(code: "SUP-T1", name: "테스트철강", lead_time_seconds: 120)
    @parts_supplier = Supplier.create!(code: "SUP-T2", name: "테스트부품", lead_time_seconds: 180)
    SupplierProduct.create!(supplier: @steel_supplier, product: @steel)
    SupplierProduct.create!(supplier: @parts_supplier, product: @bolt)
    @log = StringIO.new
    @seq = 0
  end

  def inbound(now) = Simulation::Inbound.call(now: now, logger: Logger.new(@log))

  # 다음 발주 판단을 지금 하게 한다.
  def due!(at, scheduled: at - 1)
    InboundState.delete_all
    InboundState.create!(next_truck_at: scheduled)
  end

  # 발주 판단 시각을 먼 미래로 미룬다(발주 없이 도착·하차만 보고 싶을 때).
  def quiet!
    InboundState.delete_all
    InboundState.create!(next_truck_at: NOW + 1.day)
  end

  # 발주 라인 순서대로 자재 sku. 발주할 때 고른 자재를 본다.
  def ordered_skus = PurchaseOrderLine.order(:id).includes(:product).map { |l| l.product.sku }

  # 마지막 발주의 팔레트 수.
  def ordered_pallets = (PurchaseOrderLine.order(:id).last.qty_ordered / P).to_i

  # 이미 진행 중인 발주를 손으로 만든다.
  def make_po(product, supplier, pallets:, status: "confirmed", expected_at: NOW, ordered_at: NOW - 120)
    po = PurchaseOrder.create!(po_no: PurchaseOrder.next_po_no(ordered_at), supplier: supplier, status: status,
                               ordered_at: ordered_at, expected_at: expected_at)
    po.lines.create!(product: product, qty_ordered: pallets * P)
    po
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
    # 하차가 끝났으면 입고대에 팔레트가 있다. 적치 계획이 가용 재고를 다시 확인하므로 재고도 같이 만든다.
    Inventory::Move.call(product: product, lot: lot, from: "supplier", to: "receiving", qty: P, move_type: "receive",
                         ref: nil, idempotency_key: next_key)
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

  test "시계를 흘리면 트럭 간격은 3~6분이고 예정 시각에서 10초 안에 도착한다" do
    drive(Time.current.change(usec: 0), 3600)

    schedule = @schedule.map(&:last)
    assert_operator schedule.size, :>=, 10, "한 시간에 예정이 10번 이상 바뀐다(간격 최대 6분)"
    schedule.each_cons(2) { |a, b| assert_includes 180..360, b - a, "간격 #{b - a}초" }
    @schedule.each_cons(2) do |(_, prev), (called, _)|
      assert_operator called - prev, :>=, 0
      assert_operator called - prev, :<, 10, "예정 #{prev} 인데 #{called} 에 도착"
    end
    assert_operator truck_lots.count, :>=, 2, "두 자재 모두 실려 온다"
  end

  test "팔레트마다 unload 1건·putaway 1건이고, 이동 시각이 서로 달라 같은 초에 2건 이하다" do
    t = drive(Time.current.change(usec: 0), 3600)
    @machine.update!(state: "stopped") # 수요가 0 이 되어 새 발주가 없다
    drive(t, 1800) # 이미 낸 발주가 도착해 하차·적치가 끝날 때까지

    unloads = Task.where(kind: "unload").order(:id).to_a
    assert_operator unloads.size, :>=, 8
    assert unloads.all? { |u| u.status == "done" }, "하차가 전부 끝났다"
    unloads.group_by(&:lot_id).each_value { |list| assert_includes 4..12, list.size, "트럭당 팔레트 4~12개" }
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
    assert_equal ["done"], PurchaseOrder.distinct.pluck(:status), "발주가 전부 입고 완료로 닫혔다"
    assert PurchaseOrderLine.all.all? { |l| l.qty_received == l.qty_ordered }, "라인마다 주문량만큼 받았다"
    assert_equal unloads.sum(&:qty), PurchaseOrderLine.sum(:qty_received)
    assert_equal [], Inventory::Reconcile.call
    assert_equal 0, @log.string.lines.grep(/ERROR/).size
  end

  test "발주: 먼저 PO(confirmed)만 만들고 하차는 리드타임이 지나 도착한 뒤에야 계획된다" do
    due!(NOW)

    ordered = inbound(NOW)

    assert_equal [1, 0, 0], [ordered[:orders], ordered[:arrived], ordered[:unload]]
    assert_equal 0, Task.where(kind: "unload").count, "발주만으로는 하차 작업이 없다"
    po = PurchaseOrder.sole
    assert_equal ["PO-20261008-0001", "confirmed", @steel_supplier.id, NOW, NOW + 120], [po.po_no, po.status, po.supplier_id, po.ordered_at, po.expected_at]
    assert_equal [@steel.id, 6 * P, 0], po.lines.pluck(:product_id, :qty_ordered, :qty_received).sole.map(&:to_i),
                 "둘 다 재고 0 인 동률이고 직전 발주가 없으면 id 순 첫 자재다. 팔레트는 30분 수요 올림(강판 2822 → 6)"
    assert_nil po.arrived_at

    early = inbound(NOW + 110)
    assert_equal [0, 0], [early[:arrived], early[:unload]], "리드타임 120초 전에는 도착하지 않는다"
    assert_equal 0, Task.where(kind: "unload").count

    arrived = inbound(NOW + 120)

    assert_equal [1, 6, 0], [arrived[:arrived], arrived[:unload], arrived[:orders]]
    assert_equal ["arrived", NOW + 120], po.reload.then { |r| [r.status, r.arrived_at] }
    line = po.lines.sole
    tasks = Task.where(kind: "unload")
    assert_equal 6, tasks.count, "팔레트만큼"
    assert tasks.all? { |t| t.status == "planned" && t.qty == P && t.ref_type == "PurchaseOrderLine" && t.ref_id == line.id }
    assert_equal ["R-202610081209-RAW-S"], truck_lots.pluck(:lot_no), "로트는 R-yyyymmddHHMM-sku, 도착 시각 기준"
    assert_equal [truck_lots.first.id], tasks.pluck(:lot_id).uniq

    assert_equal [0, 0], [inbound(NOW + 130)[:arrived], inbound(NOW + 140)[:unload]], "같은 발주는 두 번 도착하지 않는다"
    assert_equal 6, Task.where(kind: "unload").count
  end

  test "발주는 공급사 리드타임을 따른다: 볼트는 180초" do
    roomy_bins!
    seed_bin(@steel, "RAW-A-01-01", 10_000)
    due!(NOW)

    inbound(NOW)

    po = PurchaseOrder.sole
    assert_equal [@parts_supplier.id, NOW + 180], [po.supplier_id, po.expected_at]
    assert_equal ["RAW-B"], ordered_skus
  end

  test "진행 중 PO 가 있는 자재는 같은 자재를 또 발주하지 않는다: 열린 발주가 모든 후보에 있으면 이번 판단은 발주 없이 지나간다" do
    roomy_bins!
    seed_bin(@bolt, "RAW-A-01-01", 10_000) # 볼트는 넉넉하다. 강판만 부족하다.
    due!(NOW)
    inbound(NOW)
    due!(NOW + 10)

    second = inbound(NOW + 10)

    assert_equal %w[RAW-S RAW-B], ordered_skus, "강판 발주가 열려 있으니 다음은 강판이 아니라 (넉넉해도) 볼트다"
    assert_equal 1, second[:orders]

    due!(NOW + 20)
    third = inbound(NOW + 20)

    assert_equal 0, third[:orders], "강판·볼트 모두 열린 발주가 있다"
    assert_equal 2, PurchaseOrder.count
    assert_operator InboundState.pick(:next_truck_at), :>, NOW + 20, "발주는 안 했어도 다음 판단 시각은 잡는다"
  end

  test "도착해서 하차 중인 발주도 열린 발주다: 하차가 끝나 done 이 되면 다음 발주가 나간다" do
    roomy_bins!
    @machine.update!(state: "running")
    BomLine.where(component: @bolt).delete_all # 강판만 수요가 있다
    make_po(@steel, @steel_supplier, pallets: 4, status: "arrived", expected_at: NOW - 60, ordered_at: NOW - 180).update!(arrived_at: NOW - 60)
    due!(NOW)

    assert_equal 0, inbound(NOW)[:orders]

    PurchaseOrder.update_all(status: "done")
    due!(NOW + 10)
    assert_equal 1, inbound(NOW + 10)[:orders]
  end

  test "8b K5: 다른 자재의 도착 전 발주·하차 계획·입고대 대기는 이 자재의 칸 여유에서 빼지 않는다(자재별 계산)" do
    codes = Simulation::Inbound.bins_under("raw_store").pluck(:code)
    Location.where(code: codes).update_all(capacity_units: P) # 칸마다 팔레트 1개
    codes.first(codes.size - 3).each { |code| seed_bin(@steel, code, P) } # 강판이 점유: 빈 칸은 3개
    make_po(@steel, @steel_supplier, pallets: 2, expected_at: NOW + 600) # 아직 도착 전인 강판 2팔레트
    Inventory::Move.call(product: @steel, lot: nil, from: "supplier", to: "receiving", qty: P, move_type: "receive",
                         ref: nil, idempotency_key: next_key) # 강판 1팔레트는 입고대에서 적치 대기(적치 작업은 아직 없다)
    Task.create!(kind: "unload", status: "planned", resource: Resource.find_by!(code: "DOCK-IN-01"), product: @steel, qty: P,
                 from_location: Location.find_by!(code: "supplier"), to_location: Location.find_by!(code: "receiving"),
                 planned_at: NOW, expected_finish_at: NOW + 90) # 하차 계획분도 강판
    due!(NOW)

    inbound(NOW)

    assert_equal %w[RAW-S RAW-B], ordered_skus
    assert_equal 3, ordered_pallets, "볼트 4팔레트를 원했고 빈 칸 3개 — 강판 입고 대기는 볼트 몫을 깎지 않는다"
  end

  test "한 호출에 발주 1건만 도착한다: 밀린 발주는 10초 뒤 호출이 이어서 도착시킨다" do
    roomy_bins!
    first = make_po(@steel, @steel_supplier, pallets: 4, expected_at: NOW - 30)
    second = make_po(@bolt, @parts_supplier, pallets: 4, expected_at: NOW - 20)
    quiet!

    one = inbound(NOW)

    assert_equal [1, 4], [one[:arrived], one[:unload]]
    assert_equal %w[arrived confirmed], [first.reload.status, second.reload.status], "expected_at 이 이른 발주가 먼저다"

    two = inbound(NOW + 10)

    assert_equal [1, 4], [two[:arrived], two[:unload]]
    assert_equal %w[arrived arrived], [first.reload.status, second.reload.status]
    assert_equal 8, Task.where(kind: "unload").count
  end

  test "하차 완료가 발주 라인 qty_received 를 채우고 전 라인을 받으면 PO 가 done 이다" do
    roomy_bins!
    po = make_po(@steel, @steel_supplier, pallets: 4, expected_at: NOW - 10)
    quiet!
    inbound(NOW)
    line = po.lines.sole
    far = Time.current + 1.day

    Ops::Tick.call(now: far)
    first_batch = Task.where(kind: "unload", status: "done").count
    assert_operator first_batch, :>=, 1
    assert_equal first_batch * P, line.reload.qty_received.to_i, "하차 1건이 끝날 때마다 그 수량만큼"
    assert_equal "arrived", po.reload.status, "아직 다 받지 않았다"

    10.times { Ops::Tick.call(now: far) }

    assert_equal 4, Task.where(kind: "unload", status: "done").count
    assert_equal [4 * P, "done"], [line.reload.qty_received.to_i, po.reload.status]
    assert_equal 4 * P, StockMove.where(move_type: "receive", product: @steel).sum(:qty)
    assert_equal [], Inventory::Reconcile.call
  end

  test "하차가 모두 취소되어 다 못 받으면 발주는 cancelled 로 닫힌다. 열린 하차가 남아 있으면 아직 arrived 다" do
    roomy_bins!
    po = make_po(@steel, @steel_supplier, pallets: 2, expected_at: NOW - 10)
    quiet!
    inbound(NOW)
    first, last = Task.where(kind: "unload").order(:id).to_a

    first.update!(status: "cancelled", cancel_reason: "test")
    PurchaseOrder.unload_cancelled!(first)
    assert_equal "arrived", po.reload.status, "다른 하차가 아직 열려 있다"

    last.update!(status: "cancelled", cancel_reason: "test")
    PurchaseOrder.unload_cancelled!(last)
    assert_equal "cancelled", po.reload.status
    assert_equal 0, po.lines.sole.qty_received
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

  # 규칙을 [품목 또는 nil, 위치 code, priority] 목록으로 통째로 바꾼다.
  def rules!(*rows)
    PutawayRule.delete_all
    rows.each { |product, code, priority| PutawayRule.create!(product: product, location: Location.find_by!(code: code), priority: priority) }
  end

  test "전용 랙: 자재마다 자기 랙에 쌓이고, 전용 랙이 아닌 빈 칸은 쓰지 않는다" do
    rules!([@steel, "RAW-A-01", 10], [@bolt, "RAW-A-02", 10])
    done_unload(@steel, NOW - 40)
    done_unload(@bolt, NOW - 30)
    done_unload(@steel, NOW - 20)

    result = inbound(NOW)

    assert_equal 3, result[:putaway]
    assert_equal %w[RAW-A-01-01 RAW-A-02-01 RAW-A-01-01],
                 putaways.map { |p| p.to_location.code }, "강판은 01 랙, 볼트는 02 랙(같은 품목 칸에 남은 용량이 있으면 거기)"
  end

  test "전용 랙이 꽉 차면 공용 랙(priority 90)으로 넘어간다" do
    rules!([@steel, "RAW-A-01", 10], [nil, "RAW-A-04", 90])
    Location.where(code: Simulation::Inbound.bins_under("raw_store").pluck(:code)).update_all(capacity_units: P) # 칸마다 팔레트 1개
    Location.where("code LIKE 'RAW-A-01-%'").pluck(:code).each { |code| seed_bin(@steel, code, P) } # 전용 랙 6칸 가득
    done_unload(@steel, NOW - 10)

    inbound(NOW)

    assert_equal ["RAW-A-04-01"], putaways.map { |p| p.to_location.code }
  end

  test "priority 가 작은 규칙이 먼저고, 같으면 품목 전용이 전 품목 규칙보다 먼저다" do
    rules!([nil, "RAW-A-03", 20], [@steel, "RAW-A-02", 20], [nil, "RAW-A-01", 5])
    done_unload(@steel, NOW - 10)
    inbound(NOW)
    assert_equal ["RAW-A-01-01"], putaways.map { |p| p.to_location.code }, "priority 5 가 먼저"

    rules!([nil, "RAW-A-03", 20], [@steel, "RAW-A-02", 20])
    Task.delete_all
    done_unload(@steel, NOW - 10)
    inbound(NOW + 10)
    assert_equal ["RAW-A-02-01"], putaways.map { |p| p.to_location.code }, "priority 가 같으면 전용 규칙이 먼저"
  end

  test "비활성 규칙과 다른 품목 전용 규칙은 무시한다. 규칙이 없으면 적치하지 않는다" do
    rules!([@bolt, "RAW-A-02", 10], [@steel, "RAW-A-01", 10])
    PutawayRule.where(product: @steel).update_all(active: false)
    done_unload(@steel, NOW - 10)

    result = inbound(NOW)

    assert_equal [0, 1], [result[:putaway], result[:waiting]]
    assert_match(/적치할 칸이 없어 receiving 에 1팔레트 대기/, @log.string)
  end

  test "트럭 팔레트 수는 규칙이 열어 준 칸만 센다: 남의 전용 랙의 빈 칸은 자리가 아니다" do
    rules!([@steel, "RAW-A-01", 10], [@bolt, "RAW-A-02", 10])
    Location.where("code LIKE 'RAW-A-01-%'").update_all(capacity_units: P)
    %w[RAW-A-01-01 RAW-A-01-02 RAW-A-01-03 RAW-A-01-04].each { |code| seed_bin(@bolt, code, P) } # 강판 랙 6칸 중 4칸을 볼트가 점유
    due!(NOW)

    inbound(NOW)

    assert_equal ["RAW-S"], ordered_skus
    assert_equal 2, ordered_pallets, "6팔레트를 원했지만 강판 랙의 빈 칸은 2개(다른 랙의 빈 칸은 못 쓴다)"
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

  test "재시작해도(상태는 DB, 새 인스턴스) 같은 발주가 두 번 나가지 않는다" do
    due!(NOW)
    first = inbound(NOW)
    scheduled_after = InboundState.pick(:next_truck_at)

    repeats = [inbound(NOW), inbound(NOW + 10), inbound(NOW + 20)]

    assert_equal 1, first[:orders]
    assert_equal [0, 0, 0], repeats.map { |r| r[:orders] }
    assert_equal 1, PurchaseOrder.count
    assert_equal scheduled_after, InboundState.pick(:next_truck_at)
    assert_equal 1, InboundState.count
    assert_includes 180..360, scheduled_after - (NOW - 1)
  end

  test "상태 행이 없으면 첫 호출이 만들고 발주는 간격 뒤에 나간다" do
    assert_equal 0, InboundState.count

    result = inbound(NOW)

    assert_equal 0, result[:orders]
    assert_equal 1, InboundState.count
    assert_includes 180..360, InboundState.pick(:next_truck_at) - NOW
  end

  test "오래 멈췄다 돌아와도 발주는 1건만 나가고 다음 판단은 지금 + 간격이다" do
    due!(NOW, scheduled: NOW - 1.day)

    result = inbound(NOW)

    assert_equal 1, result[:orders]
    assert_includes 180..360, InboundState.pick(:next_truck_at) - NOW
    assert_equal 0, inbound(NOW + 10)[:orders]
  end

  test "재고가 넉넉해도 발주는 나간다: 보유 분수가 가장 작은 자재를 주문한다" do
    roomy_bins!
    seed_bin(@steel, "RAW-A-01-01", 3000) # 31.9분
    seed_bin(@bolt, "RAW-A-01-02", 1600)  # 34.0분
    due!(NOW)

    result = inbound(NOW)

    assert_equal 1, result[:orders]
    assert_equal ["RAW-S"], ordered_skus
  end

  test "재고 0 인 자재가 먼저 선택된다" do
    roomy_bins!
    seed_bin(@steel, "RAW-A-01-01", 500)
    due!(NOW)

    inbound(NOW)

    assert_equal ["RAW-B"], ordered_skus
  end

  test "동률(둘 다 보유 0)이면 직전 발주와 다른 자재다" do
    roomy_bins!
    make_po(@steel, @steel_supplier, pallets: 1, status: "done", expected_at: NOW - 480, ordered_at: NOW - 600) # 직전 발주 = 강판(끝났으니 보유량에는 안 잡힌다)
    due!(NOW)

    inbound(NOW)

    assert_equal %w[RAW-S RAW-B], ordered_skus, "id 순이면 강판이지만 직전이 강판이라 볼트"
  end

  test "수요 0 인 자재는 후보가 아니다" do
    BomLine.where(component: @steel).delete_all # 강판 수요 0, 재고 0 이어도 볼트만 주문한다
    due!(NOW)

    inbound(NOW)

    assert_equal ["RAW-B"], ordered_skus
  end

  test "공급사가 없는 자재는 후보가 아니고 로그만 남긴다" do
    SupplierProduct.where(product: @steel).delete_all # 강판은 공급사가 없다. 볼트만 주문한다
    due!(NOW)

    inbound(NOW)

    assert_equal ["RAW-B"], ordered_skus
    assert_match(/공급사가 없는 자재 #{@steel.id} 는 발주하지 않는다/, @log.string)
  end

  test "적재량 하한: 30분 수요가 3팔레트(볼트 1411)여도 4팔레트다" do
    roomy_bins!
    seed_bin(@steel, "RAW-A-01-01", 10_000)
    due!(NOW)

    inbound(NOW)

    assert_equal ["RAW-B"], ordered_skus
    assert_equal 4, ordered_pallets
  end

  test "적재량 상한: 30분 수요가 18팔레트 넘으면 12팔레트다" do
    roomy_bins!
    fg2 = Product.create!(sku: "FG-X", name: "대형", uom: "ea", kind: "fg")
    BomLine.create!(product: fg2, component: @steel, qty_per: 10) # M2 양품 0.48/s × 10 = 288/분 + 94/분 → 30분 11,462 → 23팔레트
    WorkOrder.create!(code: "WO-I2", machine: Machine.create!(code: "M2", name: "프레스", state: "running"), item: fg2,
                      product: "대형", target_qty: 100_000, status: "active", started_at: NOW)
    due!(NOW)

    inbound(NOW)

    assert_equal ["RAW-S"], ordered_skus
    assert_equal 12, ordered_pallets
  end

  test "칸이 모자라면 남은 칸 용량만큼 주문하고, 빈 칸이 없으면 발주하지 않는다" do
    codes = Simulation::Inbound.bins_under("raw_store").pluck(:code)
    Location.where(code: codes).update_all(capacity_units: P) # 칸마다 팔레트 1개
    codes.first(codes.size - 2).each { |code| seed_bin(@bolt, code, P) } # 볼트가 점유: 강판이 들어갈 칸은 2개
    due!(NOW)

    inbound(NOW)

    assert_equal ["RAW-S"], ordered_skus
    assert_equal 2, ordered_pallets, "6팔레트를 원했지만 빈 칸이 2개"

    # 8c: 8b K5 가 칸 여유를 자재별로 세게 바꿨다 — 강판의 하차 계획분은 볼트의 빈 칸을 깎지 않는다. 그래서 "빈 칸이 없다"는 상황은
    # 칸 자체가 다 찬 것으로 만든다(남은 2칸에 강판이 실제로 들어 있다). 강판은 열린 발주가 있어 후보가 아니고, 볼트는 빈 칸 0 이다.
    codes.last(2).each { |code| seed_bin(@steel, code, P) }
    due!(NOW + 600)
    again = inbound(NOW + 600)

    assert_equal 0, again[:orders]
    assert_equal 1, PurchaseOrder.count
    assert_operator InboundState.pick(:next_truck_at), :>, NOW + 600
  end

  test "10분 경계에서만 자재별 coverage 와 총수요/총공급을 로그로 남긴다" do
    roomy_bins!
    seed_bin(@steel, "RAW-A-01-01", 940) # 10.0분
    boundary = Time.utc(2026, 10, 8, 12, 10, 0)

    inbound(boundary - 10)
    assert_no_match(/sim inbound balance/, @log.string)

    inbound(boundary)

    line = @log.string.lines.grep(/sim inbound balance/).first
    assert_match(/coverage\[RAW-S=10\.0min RAW-B=0\.0min\] demand_per_min=141\.1 supply_per_min=0\.0 supply\/demand=0\.0/, line)
  end

  test "소비가 없으면(기계 정지) 발주도 트럭도 없다" do
    @machine.update!(state: "stopped")
    due!(NOW)

    assert_equal 0, inbound(NOW)[:orders]
    assert_equal 0, PurchaseOrder.count
    assert_equal 0, Task.count
    assert_operator InboundState.pick(:next_truck_at), :>, NOW, "발주는 안 해도 다음 판단 시각은 잡는다"
  end

  test "가장 모자란 자재를 싣는다: 다른 자재가 더 부족하면 그쪽이다" do
    roomy_bins!
    seed_bin(@steel, "RAW-A-01-01", 2800) # 부족 22.4, 볼트는 1411.2
    due!(NOW)

    inbound(NOW)
    quiet! # 새 발주 판단 없이 도착만 본다
    inbound(NOW + 180) # 볼트 리드타임 180초 뒤 도착: 실려 온 로트도 같은 자재다

    assert_equal ["RAW-B"], ordered_skus
    assert_equal ["R-202610081210-RAW-B"], truck_lots.pluck(:lot_no)
  end

  test "line_side 에 있는 재고도 센다: line_side 가 넉넉한 자재는 raw 칸이 비어도 건너뛴다" do
    roomy_bins!
    seed_bin(@steel, "RAW-A-01-01", 3000)
    Inventory::Move.call(product: @steel, lot: nil, from: "RAW-A-01-01", to: "line_side", qty: 3000, move_type: "feed",
                         ref: nil, idempotency_key: next_key) # raw 칸 0, line_side 3000(필요 2822.4 이상)
    due!(NOW)

    inbound(NOW)

    assert_equal ["RAW-B"], ordered_skus, "강판은 line_side 에 넉넉하니 raw 칸이 비어도 볼트를 발주한다"
  end

  test "이미 계획된 하차분도 입고 예정으로 센다" do
    roomy_bins!
    seed_bin(@steel, "RAW-A-01-01", 2000) # 21.3분
    Task.create!(kind: "unload", status: "planned", product: @bolt, qty: 1500, planned_at: NOW + 60, from_location: Location.find_by!(code: "supplier"),
                 to_location: Location.find_by!(code: "receiving")) # 볼트 31.9분(하차 계획분이 없으면 0분이라 볼트가 뽑힌다)
    due!(NOW)

    inbound(NOW)

    assert_equal ["RAW-S"], ordered_skus, "볼트는 하차 계획분 1500 이 입고 예정으로 잡혀 강판이 더 모자라다"
  end

  test "자원이 없어 하차 계획이 실패하면 도착 처리 전체가 롤백되고 예외 없이 로그만 남으며, 자원이 생기면 다음 호출에 도착한다" do
    Resource.delete_all
    po = make_po(@steel, @steel_supplier, pallets: 2, expected_at: NOW - 10)
    quiet!

    result = inbound(NOW)

    assert_equal [0, 0], [result[:arrived], result[:unload]]
    assert_equal 0, Task.count
    assert_equal 0, truck_lots.count, "로트도 같이 롤백된다"
    assert_equal ["confirmed", nil], [po.reload.status, po.arrived_at], "발주는 아직 도착 전으로 남는다"
    assert_equal 1, @log.string.lines.grep(/sim inbound arrive .*NoResource/).size

    Resource.ensure_defaults!
    again = inbound(NOW + 10)

    assert_equal [1, 2], [again[:arrived], again[:unload]]
    assert_equal "arrived", po.reload.status
  end

  test "적치 단계가 실패해도 같은 호출의 발주는 나간다" do
    done_unload(@steel, NOW - 10)
    due!(NOW)
    original = Simulation::Inbound.instance_method(:plan_putaways)
    Simulation::Inbound.send(:define_method, :plan_putaways) { raise "적치 실패" }
    begin
      result = inbound(NOW)
    ensure
      Simulation::Inbound.send(:define_method, :plan_putaways, original)
    end

    assert_equal 1, result[:orders]
    assert_equal 1, PurchaseOrder.count
    assert_equal 1, @log.string.lines.grep(/sim inbound putaway .*적치 실패/).size
  end

  # --- 재주문점(reorder_rules) ---------------------------------------------------------------

  def reorder!(product, min: 15, max: 30) = ReorderRule.create!(product: product, min_minutes: min, max_minutes: max)

  test "재주문점: 모든 자재의 coverage 가 min 이상이면 발주하지 않고 다음 판단 시각만 잡는다" do
    roomy_bins!
    reorder!(@steel)
    reorder!(@bolt)
    seed_bin(@steel, "RAW-A-01-01", 1500) # 15.9분 (분당 94.08)
    seed_bin(@bolt, "RAW-A-01-02", 750)   # 15.9분 (분당 47.04)
    due!(NOW)

    result = inbound(NOW)

    assert_equal 0, result[:orders]
    assert_equal 0, PurchaseOrder.count
    assert_operator InboundState.pick(:next_truck_at), :>, NOW
  end

  test "재주문점: min 아래로 떨어진 자재만 후보고, 발주량은 max 분어치까지 채운다" do
    roomy_bins!
    reorder!(@steel)
    reorder!(@bolt)
    seed_bin(@steel, "RAW-A-01-01", 500) # 5.3분 < 15
    seed_bin(@bolt, "RAW-A-01-02", 750)  # 15.9분 ≥ 15: 후보가 아니다
    due!(NOW)

    inbound(NOW)

    assert_equal ["RAW-S"], ordered_skus
    assert_equal 5, ordered_pallets, "ceil((30 x 94.08 − 500) / 500) = 5. 규칙이 없으면 30분 수요만으로 6"
    assert_operator 500 + (5 * P), :>=, 30 * 94.08
    assert_operator 500 + (4 * P), :<, 30 * 94.08
  end

  test "재주문점: coverage 가 가장 작은 자재가 min 이상이면 건너뛰고 min 아래인 다른 자재를 주문한다" do
    roomy_bins!
    reorder!(@steel, min: 3, max: 30) # 강판 500/94.08 = 5.3분 ≥ 3: 가장 작지만 후보가 아니다
    reorder!(@bolt)                   # 볼트 470/47.04 = 10.0분 < 15: 후보
    seed_bin(@steel, "RAW-A-01-01", 500)
    seed_bin(@bolt, "RAW-A-01-02", 470)
    due!(NOW)

    inbound(NOW)

    assert_equal ["RAW-B"], ordered_skus
  end

  test "재주문점: 규칙이 없거나 비활성인 자재는 예전처럼 coverage 가 작은 것부터 후보다" do
    roomy_bins!
    reorder!(@steel).update!(active: false)
    reorder!(@bolt)
    seed_bin(@steel, "RAW-A-01-01", 2000) # 21.3분: 규칙이 살아 있었다면 min(15) 이상이라 후보가 아니다
    seed_bin(@bolt, "RAW-A-01-02", 1000)  # 21.3분 ≥ 15: 후보가 아니다
    due!(NOW)

    inbound(NOW)

    assert_equal ["RAW-S"], ordered_skus, "비활성 규칙은 무시되므로 강판은 필터 없이 후보로 남고 볼트만 빠진다"
  end

  test "재주문점: 발주량은 상한·칸 여유로 자른다" do
    roomy_bins!
    reorder!(@steel, min: 15, max: 600) # 600분어치 = 56,448 → 12팔레트 상한
    due!(NOW)

    inbound(NOW)

    assert_equal ["RAW-S"], ordered_skus.first(1)
    assert_equal 12, PurchaseOrderLine.where(product: @steel).sum(:qty_ordered) / P
  end
end
