require "test_helper"

class Inventory::ShipTest < ActiveSupport::TestCase
  setup do
    @bracket = Product.create!(sku: "FG-BR", name: "브래킷", uom: "ea", kind: "fg")
    @lot = Lot.create!(product: @bracket, lot_no: "WO-SHIP")
    @order = SalesOrder.create!(so_no: "SO-1", customer: "테스트고객")
    @line = SalesOrderLine.create!(sales_order: @order, product: @bracket, ordered_qty: 10)
    # 출하대에 20개: 생산 → 검사대 → 합격 → 출하대로 pick
    Inventory::Move.call(product: @bracket, lot: @lot, from: Location.find_by!(code: "production"),
                         to: Location.find_by!(code: "qc"), qty: 20, move_type: "produce", ref: nil,
                         idempotency_key: "seed-produce")
    Inventory::Move.call(product: @bracket, lot: @lot, from: Location.find_by!(code: "qc"),
                         to: Location.find_by!(code: "fg_store"), qty: 20, move_type: "qc_pass", ref: nil,
                         idempotency_key: "seed-pass")
    Inventory::Move.call(product: @bracket, lot: @lot, from: Location.find_by!(code: "fg_store"),
                         to: Location.find_by!(code: "shipping"), qty: 20, move_type: "pick", ref: nil,
                         idempotency_key: "seed-pick")
  end

  def ship(qty, key)
    Inventory::Ship.call(sales_order_line: @line, lot: @lot, qty: qty, idempotency_key: key)
  end

  test "일부 출하는 partial, 전량 출하는 done" do
    ship(4, "ship-1")
    assert_equal "partial", @order.reload.status

    ship(6, "ship-2")
    assert_equal "done", @order.reload.status
  end

  test "주문량을 넘기는 출하는 예외이고 이동도 상태도 안 바뀐다" do
    ship(8, "ship-1")

    assert_raises(Inventory::Ship::OverShipment) { ship(3, "ship-2") }
    assert_equal 1, StockMove.where(move_type: "ship").count
    assert_equal "partial", @order.reload.status
  end

  test "같은 멱등키 재호출은 전량 출하 뒤에도 예외 없이 같은 이동을 돌려준다" do
    first = ship(10, "ship-full")
    again = ship(10, "ship-full")

    assert_equal first.id, again.id
    assert_equal 1, StockMove.where(move_type: "ship").count
  end

  test "출하는 출하대에서 고객으로 나가고 완제품창고 재고는 건드리지 않는다" do
    move = ship(4, "ship-path")

    assert_equal %w[shipping customer], [move.from_location.code, move.to_location.code]
    assert_equal 16, Quant.where(product_id: @bracket.id, location: Location.find_by!(code: "shipping")).sum(:qty)
  end

  test "pick 하지 않은 완제품창고 재고는 바로 출하할 수 없다" do
    other = Lot.create!(product: @bracket, lot_no: "WO-SHIP-2")
    Inventory::Move.call(product: @bracket, lot: other, from: "production", to: "qc", qty: 5, move_type: "produce", ref: nil,
                         idempotency_key: "seed-produce-2")
    Inventory::Move.call(product: @bracket, lot: other, from: "qc", to: "fg_store", qty: 5, move_type: "qc_pass", ref: nil,
                         idempotency_key: "seed-pass-2")

    assert_raises(Inventory::InsufficientStock) do
      Inventory::Ship.call(sales_order_line: @line, lot: other, qty: 5, idempotency_key: "ship-unpicked")
    end
    assert_equal 0, StockMove.where(move_type: "ship").count
  end
end
