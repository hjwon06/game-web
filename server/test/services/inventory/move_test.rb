require "test_helper"

class Inventory::MoveTest < ActiveSupport::TestCase
  setup do
    @product = Product.create!(sku: "RAW-1", name: "강판", uom: "kg", kind: "raw")
    @supplier = Location.find_by!(code: "supplier")
    @receiving = Location.find_by!(code: "receiving")
    @raw_store = Location.find_by!(code: "raw_store")
  end

  def move(from:, to:, qty:, type:, key:)
    Inventory::Move.call(product: @product, lot: nil, from: from, to: to, qty: qty, move_type: type, ref: nil,
                         idempotency_key: key)
  end

  def on_hand(location)
    Quant.where(product_id: @product.id, location_id: location.id).sum(:qty)
  end

  test "입고는 원장 1건을 만들고 공급처는 마이너스, 입고대는 플러스가 된다" do
    m = move(from: @supplier, to: @receiving, qty: 10, type: "receive", key: "k-recv-1")

    assert_equal "receive", m.move_type
    assert_equal(-10, on_hand(@supplier))
    assert_equal 10, on_hand(@receiving)
  end

  test "같은 멱등키 2회는 이동 1건이고 재고는 한 번만 바뀐다" do
    first = move(from: @supplier, to: @receiving, qty: 10, type: "receive", key: "k-dup")
    second = move(from: @supplier, to: @receiving, qty: 10, type: "receive", key: "k-dup")

    assert_equal first.id, second.id
    assert_equal 1, StockMove.where(idempotency_key: "k-dup").count
    assert_equal 10, on_hand(@receiving)
  end

  test "물리 위치 재고가 모자라면 InsufficientStock 이고 원장도 재고도 안 바뀐다" do
    move(from: @supplier, to: @receiving, qty: 3, type: "receive", key: "k-recv-2")

    assert_raises(Inventory::InsufficientStock) do
      move(from: @receiving, to: @raw_store, qty: 5, type: "putaway", key: "k-putaway-1")
    end
    assert_equal 0, StockMove.where(idempotency_key: "k-putaway-1").count
    assert_equal 3, on_hand(@receiving)
    assert_equal 0, on_hand(@raw_store)
  end

  test "허용 경로를 어기면 InvalidPath" do
    assert_raises(Inventory::Move::InvalidPath) do
      move(from: @supplier, to: @raw_store, qty: 1, type: "receive", key: "k-bad-path")
    end
    assert_equal 0, StockMove.count
  end
end
