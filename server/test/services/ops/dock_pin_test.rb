require "test_helper"

# 트럭 1대 = 도크 1곳: 같은 발주(수주)의 하차(상차)는 이미 열린 작업이 있는 도크로 계획된다.
class OpsDockPinTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers
  T0 = Time.utc(2026, 10, 8, 12, 0, 0)

  setup do
    travel_to T0
    Ops::Plan.reseed!(11)
    @raw = Product.create!(sku: "RAW-DK", name: "강판", uom: "ea", kind: "raw")
    @fg = Product.create!(sku: "FG-DK", name: "브래킷", uom: "ea", kind: "fg")
    supplier = Supplier.create!(code: "SUP-DK", name: "도크공급사", lead_time_seconds: 60)
    @po = PurchaseOrder.create!(po_no: "PO-DK-1", supplier: supplier, status: "arrived", ordered_at: T0, expected_at: T0)
    @po_lines = 3.times.map { @po.lines.create!(product: @raw, qty_ordered: 500) }
    @other = PurchaseOrder.create!(po_no: "PO-DK-2", supplier: supplier, status: "arrived", ordered_at: T0, expected_at: T0)
    @other_line = @other.lines.create!(product: @raw, qty_ordered: 500)
  end

  teardown { travel_back }

  def unload(line) = Ops::Plan.call(kind: "unload", product: @raw, lot: nil, qty: 500, from: "supplier", to: "receiving", ref: line, earliest_at: T0)

  test "같은 발주의 하차는 모두 같은 입고 도크다 (첫 도크가 바빠져 다른 도크가 더 일러도)" do
    first = unload(@po_lines[0])
    # 첫 도크를 오래 붙잡아 둬도, 다른 도크가 비어 있어도 같은 발주는 그 도크를 쓴다
    first.update_columns(expected_finish_at: T0 + 1.hour)
    docks = @po_lines.drop(1).map { |l| unload(l).resource_id }

    assert_equal [first.resource_id] * 2, docks
    assert_equal 1, Task.where(kind: "unload", ref_type: "PurchaseOrderLine", ref_id: @po_lines.map(&:id)).distinct.count(:resource_id)
  end

  test "다른 발주는 이 고정에 묶이지 않고 가장 이른 도크로 간다" do
    first = unload(@po_lines[0])
    first.update_columns(expected_finish_at: T0 + 1.hour)

    assert_not_equal first.resource_id, unload(@other_line).resource_id
  end

  test "열린 하차가 없으면(전부 끝났으면) 고정하지 않는다" do
    first = unload(@po_lines[0])
    first.update_columns(status: "done", started_at: T0, finished_at: T0)

    assert_includes Resource.where(kind: "dock_in").pluck(:id), unload(@po_lines[1]).resource_id
  end
end
