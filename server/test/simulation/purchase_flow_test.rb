require "test_helper"
require "stringio"

# 발주 흐름 한 바퀴: PO 생성(confirmed) -> 리드타임 전에는 하차 0 -> 도착(arrived) 후 팔레트만큼 unload 계획 -> 하차 완료로 qty_received 가 차고 done.
class PurchaseFlowTest < ActiveSupport::TestCase
  include UnscaledRatesHelper
  NOW = Time.utc(2026, 10, 8, 12, 7, 30)
  P = Simulation::Config::PALLET_QTY
  LEAD = 120

  setup do
    Resource.ensure_defaults!
    Ops::Plan.reseed!(41)
    @steel = Product.create!(sku: "RAW-S", name: "강판", uom: "ea", kind: "raw")
    @bolt = Product.create!(sku: "RAW-B", name: "볼트", uom: "ea", kind: "raw")
    @fg = Product.create!(sku: "FG-BR", name: "브래킷", uom: "ea", kind: "fg")
    PutawayRule.create!(product: nil, location: Location.find_by!(code: "raw_store"), priority: 100)
    BomLine.create!(product: @fg, component: @steel, qty_per: 2)
    BomLine.create!(product: @fg, component: @bolt, qty_per: 1)
    machine = Machine.create!(code: "M1", name: "절단기", state: "running")
    WorkOrder.create!(code: "WO-PF1", machine: machine, item: @fg, product: "브래킷", target_qty: 100_000,
                      status: "active", started_at: NOW)
    supplier = Supplier.create!(code: "SUP-PF", name: "흐름공급사", lead_time_seconds: LEAD)
    SupplierProduct.create!(supplier: supplier, product: @steel)
    SupplierProduct.create!(supplier: supplier, product: @bolt)
    @log = StringIO.new
  end

  def inbound(now) = Simulation::Inbound.call(now: now, logger: Logger.new(@log))

  # 다음 발주 판단 시각을 정한다.
  def schedule!(at)
    InboundState.delete_all
    InboundState.create!(next_truck_at: at)
  end

  def unloads = Task.where(kind: "unload").order(:id)

  test "발주 -> 리드타임 전 하차 0 -> 도착 후 팔레트만큼 unload -> 하차 완료로 qty_received 가 차고 done" do
    schedule!(NOW - 1)
    ordered = inbound(NOW)

    assert_equal 1, ordered[:orders]
    po = PurchaseOrder.sole
    line = po.lines.sole
    pallets = (line.qty_ordered / P).to_i
    assert_operator pallets, :>=, 4
    assert_equal ["confirmed", NOW + LEAD, 0], [po.status, po.expected_at, line.qty_received.to_i]

    schedule!(NOW + 1.day) # 이후로는 새 발주 판단 없이 도착·하차만 본다
    early = inbound(NOW + LEAD - 1)
    assert_equal [0, 0], [early[:arrived], early[:unload]], "리드타임 전에는 하차 계획이 없다"
    assert_equal 0, unloads.count
    assert_equal "confirmed", po.reload.status

    arrived = inbound(NOW + LEAD)
    assert_equal [1, pallets], [arrived[:arrived], arrived[:unload]], "도착하면 팔레트 수만큼 하차를 계획한다"
    assert_equal "arrived", po.reload.status
    assert_equal pallets, unloads.count
    assert unloads.all? { |t| t.status == "planned" && t.qty == P && t.ref_type == "PurchaseOrderLine" && t.ref_id == line.id }
    assert_equal 0, line.reload.qty_received.to_i, "계획만으로는 받은 게 없다"

    far = Time.current + 1.day
    (pallets + 4).times { Ops::Tick.call(now: far) } # 자원마다 한 번에 1건씩 끝낸다

    assert_equal pallets, unloads.where(status: "done").count, "하차가 전부 끝났다"
    assert_equal [pallets * P, "done"], [line.reload.qty_received.to_i, po.reload.status]
    assert_equal line.qty_ordered, line.qty_received
    assert_equal pallets * P, StockMove.where(move_type: "receive", product_id: line.product_id).sum(:qty)
    assert_equal [], Inventory::Reconcile.call
    assert_equal 0, @log.string.lines.grep(/ERROR/).size
  end

  test "진행 중 PO 가 있으면 같은 자재를 또 발주하지 않고, 하차까지 끝나 done 이 되면 다시 발주한다" do
    # 수요는 강판·볼트 둘이다. 판단을 3번 해도 열린 발주가 자재마다 하나뿐이다.
    3.times do |i|
      schedule!(NOW + (i * 10) - 1)
      inbound(NOW + (i * 10))
    end

    skus = PurchaseOrderLine.order(:id).includes(:product).map { |l| l.product.sku }
    assert_equal %w[RAW-B RAW-S], skus.sort, "두 자재가 하나씩만 나갔다"
    assert_equal 2, PurchaseOrder.count

    # 도착해서 하차 중인 발주도 열린 발주다.
    schedule!(NOW + 1.day)
    inbound(NOW + 200)
    assert_equal %w[arrived], PurchaseOrder.where(status: "arrived").pluck(:status).uniq
    schedule!(NOW + 200 - 1)
    assert_equal 0, inbound(NOW + 200)[:orders], "도착(arrived)해 하차 중인 자재도 막는다"

    PurchaseOrder.update_all(status: "done")
    schedule!(NOW + 300 - 1)
    assert_equal 1, inbound(NOW + 300)[:orders], "발주가 닫히면 다시 낼 수 있다"
  end

  test "한 호출에는 발주 1건만 도착한다" do
    schedule!(NOW + 1.day)
    supplier = Supplier.first
    [@steel, @bolt].each_with_index do |product, i|
      po = PurchaseOrder.create!(po_no: PurchaseOrder.next_po_no(NOW), supplier: supplier, status: "confirmed",
                                 ordered_at: NOW - 300, expected_at: NOW - 60 + i)
      po.lines.create!(product: product, qty_ordered: 2 * P)
    end

    first = inbound(NOW)
    assert_equal [1, 2], [first[:arrived], first[:unload]]
    assert_equal({ "arrived" => 1, "confirmed" => 1 }, PurchaseOrder.group(:status).count)

    second = inbound(NOW + 10)
    assert_equal [1, 2], [second[:arrived], second[:unload]]
    assert_equal({ "arrived" => 2 }, PurchaseOrder.group(:status).count)

    assert_equal [0, 0], [inbound(NOW + 20)[:arrived], inbound(NOW + 30)[:unload]], "남은 도착이 없다"
    assert_equal 4, unloads.count
  end
end
