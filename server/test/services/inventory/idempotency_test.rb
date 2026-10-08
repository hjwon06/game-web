require "test_helper"

# 같은 멱등키는 이동 1건, 재고는 한 번만 바뀐다. 두 번째 호출의 인자가 달라도 처음 결과가 유지된다.
class Inventory::IdempotencyTest < ActiveSupport::TestCase
  setup do
    @product = Product.create!(sku: "RAW-IDEM", name: "멱등 자재", uom: "ea", kind: "raw")
  end

  def receive(qty, key)
    Inventory::Move.call(product: @product, lot: nil, from: "supplier", to: "receiving", qty: qty, move_type: "receive",
                         ref: nil, idempotency_key: key)
  end

  def receiving_qty
    Quant.where(product_id: @product.id, location_id: Location.find_by!(code: "receiving").id).sum(:qty)
  end

  test "같은 멱등키 2회는 이동 1건이고 입고대 재고는 한 번만 늘어난다" do
    first = receive(10, "idem-1")
    second = receive(10, "idem-1")

    assert_equal first.id, second.id
    assert_equal 1, StockMove.where(idempotency_key: "idem-1").count
    assert_equal 10, receiving_qty
  end

  test "같은 키에 다른 수량이면 IdempotencyConflict 이고 새 이동도 재고 변화도 없다" do
    receive(10, "idem-2")

    error = assert_raises(Inventory::IdempotencyConflict) { receive(99, "idem-2") }
    assert_match(/qty/, error.message)
    assert_equal 1, StockMove.count
    assert_equal 10, receiving_qty
  end

  test "같은 키에 다른 품목·위치·유형·참조여도 IdempotencyConflict" do
    receive(10, "idem-2b")
    other = Product.create!(sku: "RAW-IDEM-2", name: "다른 자재", uom: "ea", kind: "raw")

    assert_raises(Inventory::IdempotencyConflict) do
      Inventory::Move.call(product: other, lot: nil, from: "supplier", to: "receiving", qty: 10, move_type: "receive",
                           ref: nil, idempotency_key: "idem-2b")
    end
    assert_raises(Inventory::IdempotencyConflict) do
      Inventory::Move.call(product: @product, lot: nil, from: "receiving", to: "raw_store", qty: 10, move_type: "putaway",
                           ref: nil, idempotency_key: "idem-2b")
    end
    assert_raises(Inventory::IdempotencyConflict) do
      Inventory::Move.call(product: @product, lot: nil, from: "supplier", to: "receiving", qty: 10, move_type: "receive",
                           ref: other, idempotency_key: "idem-2b")
    end
    assert_equal 1, StockMove.count
  end

  test "Ship 도 같은 키에 다른 수량이나 다른 수주 라인이면 IdempotencyConflict" do
    fg = Product.create!(sku: "FG-IDEM-SHIP", name: "멱등 출하품", uom: "ea", kind: "fg")
    lot = Lot.create!(product: fg, lot_no: "LOT-IDEM-SHIP")
    Inventory::Move.call(product: fg, lot: lot, from: "production", to: "qc", qty: 10, move_type: "produce", ref: nil,
                         idempotency_key: "idem-ship-prod")
    Inventory::Move.call(product: fg, lot: lot, from: "qc", to: "fg_store", qty: 10, move_type: "qc_pass", ref: nil,
                         idempotency_key: "idem-ship-pass")
    order = SalesOrder.create!(so_no: "SO-IDEM", customer: "멱등고객")
    line = SalesOrderLine.create!(sales_order: order, product: fg, ordered_qty: 10)
    other_order = SalesOrder.create!(so_no: "SO-IDEM-2", customer: "멱등고객2")
    other_line = SalesOrderLine.create!(sales_order: other_order, product: fg, ordered_qty: 10)

    first = Inventory::Ship.call(sales_order_line: line, lot: lot, qty: 4, idempotency_key: "idem-ship")
    assert_equal first.id, Inventory::Ship.call(sales_order_line: line, lot: lot, qty: 4, idempotency_key: "idem-ship").id

    assert_raises(Inventory::IdempotencyConflict) do
      Inventory::Ship.call(sales_order_line: line, lot: lot, qty: 5, idempotency_key: "idem-ship")
    end
    assert_raises(Inventory::IdempotencyConflict) do
      Inventory::Ship.call(sales_order_line: other_line, lot: lot, qty: 4, idempotency_key: "idem-ship")
    end
    assert_equal 1, StockMove.where(move_type: "ship").count
  end

  test "다른 키는 별개 이동이다" do
    receive(10, "idem-3")
    receive(10, "idem-4")

    assert_equal 2, StockMove.count
    assert_equal 20, receiving_qty
  end

  test "Backflush 를 같은 bucket 으로 다시 불러도 이동이 늘지 않는다" do
    steel = Product.create!(sku: "RAW-IDEM-BF", name: "멱등 강판", uom: "ea", kind: "raw")
    fg = Product.create!(sku: "FG-IDEM", name: "멱등품", uom: "ea", kind: "fg")
    BomLine.create!(product: fg, component: steel, qty_per: 1)
    Inventory::Move.call(product: steel, lot: nil, from: "supplier", to: "receiving", qty: 50, move_type: "receive",
                         ref: nil, idempotency_key: "idem-bf-recv")
    Inventory::Move.call(product: steel, lot: nil, from: "receiving", to: "raw_store", qty: 50, move_type: "putaway",
                         ref: nil, idempotency_key: "idem-bf-put")
    work_order = WorkOrder.create!(code: "WO-IDEM", machine: Machine.create!(code: "ID1", name: "멱등기"),
                                   product: "멱등품", target_qty: 10)
    bucket = Time.utc(2026, 10, 8, 10, 0, 0)

    first = Inventory::Backflush.call(work_order: work_order, produced_delta: 5, bucket_at: bucket)
    count = StockMove.count
    second = Inventory::Backflush.call(work_order: work_order, produced_delta: 5, bucket_at: bucket)

    assert_equal first.map(&:id), second.map(&:id)
    assert_equal count, StockMove.count
    assert_equal 45, Quant.where(product_id: steel.id, location_id: Location.find_by!(code: "raw_store").id).sum(:qty)
  end

  test "멱등키가 비어 있으면 거부한다" do
    assert_raises(ArgumentError) { receive(1, "") }
    assert_equal 0, StockMove.count
  end
end
