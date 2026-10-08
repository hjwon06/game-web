require "test_helper"

# 주문 100 중 70 출하 = partial, 잔량 30 출하 = done. 출하는 로트 단위라 여러 로트에 걸쳐 나간다.
class Inventory::PartialShipTest < ActiveSupport::TestCase
  setup do
    @fg = Product.create!(sku: "FG-PART", name: "부분출하품", uom: "ea", kind: "fg")
    @lot_a = Lot.create!(product: @fg, lot_no: "LOT-PART-A")
    @lot_b = Lot.create!(product: @fg, lot_no: "LOT-PART-B")
    [[@lot_a, 60], [@lot_b, 60]].each do |lot, amount|
      Inventory::Move.call(product: @fg, lot: lot, from: "production", to: "qc", qty: amount, move_type: "produce",
                           ref: nil, idempotency_key: "part-prod-#{lot.lot_no}")
      Inventory::Move.call(product: @fg, lot: lot, from: "qc", to: "fg_store", qty: amount, move_type: "qc_pass",
                           ref: nil, idempotency_key: "part-pass-#{lot.lot_no}")
      Inventory::Move.call(product: @fg, lot: lot, from: "fg_store", to: "shipping", qty: amount, move_type: "pick",
                           ref: nil, idempotency_key: "part-pick-#{lot.lot_no}")
    end
    @order = SalesOrder.create!(so_no: "SO-PART", customer: "부분고객")
    @line = SalesOrderLine.create!(sales_order: @order, product: @fg, ordered_qty: 100)
  end

  def ship(lot, qty, key)
    Inventory::Ship.call(sales_order_line: @line, lot: lot, qty: qty, idempotency_key: key)
  end

  def shipped
    StockMove.where(move_type: "ship", ref_type: "SalesOrderLine", ref_id: @line.id).sum(:qty)
  end

  def stock(lot, code)
    Quant.where(product_id: @fg.id, lot_id: lot.id, location_id: Location.find_by!(code: code).id).sum(:qty).to_i
  end

  test "100 중 70 출하는 partial 이고 잔량 30 출하는 done 이다" do
    assert_equal "open", @order.status

    ship(@lot_a, 60, "part-1")
    ship(@lot_b, 10, "part-2")
    assert_equal [70, "partial"], [shipped.to_i, @order.reload.status]

    ship(@lot_b, 30, "part-3")
    assert_equal [100, "done"], [shipped.to_i, @order.reload.status]
  end

  test "로트별 출하는 해당 로트 재고만 줄이고 고객 위치에 합산된다" do
    ship(@lot_a, 60, "part-1")
    ship(@lot_b, 10, "part-2")

    assert_equal [0, 50], [stock(@lot_a, "shipping"), stock(@lot_b, "shipping")]
    assert_equal [60, 10], [stock(@lot_a, "customer"), stock(@lot_b, "customer")]
  end

  test "partial 상태에서 잔량보다 많이 출하하면 OverShipment 이고 상태·재고가 그대로다" do
    ship(@lot_a, 60, "part-1")
    ship(@lot_b, 10, "part-2")

    assert_raises(Inventory::Ship::OverShipment) { ship(@lot_b, 31, "part-over") }

    assert_equal [70, "partial"], [shipped.to_i, @order.reload.status]
    assert_equal 50, stock(@lot_b, "shipping")
  end

  test "partial 출하를 같은 키로 다시 불러도 출하량이 늘지 않는다" do
    ship(@lot_a, 60, "part-1")
    ship(@lot_a, 60, "part-1")

    assert_equal 60, shipped.to_i
    assert_equal "partial", @order.reload.status
  end

  test "수주 라인이 둘이면 한 라인만 끝나도 수주는 partial 이다" do
    other = Product.create!(sku: "FG-PART-2", name: "부분출하품2", uom: "ea", kind: "fg")
    SalesOrderLine.create!(sales_order: @order, product: other, ordered_qty: 5)

    ship(@lot_a, 60, "part-1")
    ship(@lot_b, 40, "part-2")

    assert_equal "partial", @order.reload.status
  end
end
