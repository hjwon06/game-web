require "test_helper"

class Inventory::InspectTest < ActiveSupport::TestCase
  setup do
    @bracket = Product.create!(sku: "FG-BR", name: "브래킷", uom: "ea", kind: "fg")
    machine = Machine.create!(code: "M1", name: "절단기")
    @wo = WorkOrder.create!(code: "WO-QC", machine: machine, item: @bracket, product: "브래킷", target_qty: 100)
    @lot = Lot.create!(product: @bracket, lot_no: @wo.code)
    # BOM 없이 생산 이동만으로 검사대에 10개를 올린다.
    Inventory::Move.call(product: @bracket, lot: @lot, from: Location.find_by!(code: "production"),
                         to: Location.find_by!(code: "qc"), qty: 10, move_type: "produce", ref: @wo,
                         idempotency_key: "seed-produce")
  end

  def qty_at(code)
    Quant.where(product_id: @bracket.id, lot_id: @lot.id, location_id: Location.find_by!(code: code).id).sum(:qty)
  end

  test "합격은 완제품창고로, 불합격은 폐기로 이동하고 검사 행이 남는다" do
    inspections = Inventory::Inspect.call(lot: @lot, work_order: @wo, pass_qty: 8, fail_qty: 2)

    assert_equal %w[pass fail], inspections.map(&:result)
    assert_equal [0, 2], inspections.map { |i| i.defect_qty.to_i }
    assert_equal 8, qty_at("fg_store")
    assert_equal 2, qty_at("scrap")
    assert_equal 0, qty_at("qc")
  end

  test "검사대 재고보다 많이 검사하면 거부되고 검사 행도 안 남는다" do
    assert_raises(Inventory::InsufficientStock) do
      Inventory::Inspect.call(lot: @lot, work_order: @wo, pass_qty: 11, fail_qty: 0)
    end
    assert_equal 0, Inspection.count
  end

  test "같은 idempotency_key 재호출은 검사 행을 늘리지 않는다" do
    Inventory::Inspect.call(lot: @lot, work_order: @wo, pass_qty: 4, fail_qty: 1, idempotency_key: "insp-1")
    Inventory::Inspect.call(lot: @lot, work_order: @wo, pass_qty: 4, fail_qty: 1, idempotency_key: "insp-1")

    assert_equal 2, Inspection.count
    assert_equal 4, qty_at("fg_store")
  end
end
