require "test_helper"

class Inventory::BackflushTest < ActiveSupport::TestCase
  setup do
    @steel = Product.create!(sku: "RAW-S", name: "강판", uom: "kg", kind: "raw")
    @bolt = Product.create!(sku: "RAW-B", name: "볼트", uom: "ea", kind: "raw")
    @bracket = Product.create!(sku: "FG-BR", name: "브래킷", uom: "ea", kind: "fg")
    BomLine.create!(product: @bracket, component: @steel, qty_per: 2)
    BomLine.create!(product: @bracket, component: @bolt, qty_per: 4)
    machine = Machine.create!(code: "M1", name: "절단기")
    @wo = WorkOrder.create!(code: "WO-BF", machine: machine, item: @bracket, product: "브래킷", target_qty: 100)
    @bucket = Time.utc(2026, 10, 8, 9, 0, 0)
  end

  def stock_raw(product, qty)
    Inventory::Move.call(product: product, lot: nil, from: Location.find_by!(code: "supplier"),
                         to: Location.find_by!(code: "receiving"), qty: qty, move_type: "receive", ref: nil,
                         idempotency_key: "seed-recv-#{product.id}")
    Inventory::Move.call(product: product, lot: nil, from: Location.find_by!(code: "receiving"),
                         to: Location.find_by!(code: "raw_store"), qty: qty, move_type: "putaway", ref: nil,
                         idempotency_key: "seed-put-#{product.id}")
    # 백플러시는 라인 공급대(line_side)에서 뺀다: raw_store → line_side(feed) 까지 올려 둔다.
    Inventory::Move.call(product: product, lot: nil, from: Location.find_by!(code: "raw_store"),
                         to: Location.find_by!(code: "line_side"), qty: qty, move_type: "feed", ref: nil,
                         idempotency_key: "seed-feed-#{product.id}")
  end

  test "생산 증분만큼 자재를 출고하고 완제품 1건을 검사대로 보낸다, 재호출은 멱등" do
    stock_raw(@steel, 100)
    stock_raw(@bolt, 100)

    moves = Inventory::Backflush.call(work_order: @wo, produced_delta: 5, bucket_at: @bucket)
    again = Inventory::Backflush.call(work_order: @wo, produced_delta: 5, bucket_at: @bucket)

    assert_equal %w[issue issue produce], moves.map(&:move_type)
    assert_equal moves.map(&:id), again.map(&:id)
    line_side = Location.find_by!(code: "line_side")
    assert_equal 90, Quant.find_by!(product_id: @steel.id, location_id: line_side.id).qty
    assert_equal 80, Quant.find_by!(product_id: @bolt.id, location_id: line_side.id).qty
    assert_equal 5, Quant.find_by!(product_id: @bracket.id, location_id: Location.find_by!(code: "qc").id).qty
  end

  test "자재가 하나라도 모자라면 전부 롤백된다" do
    stock_raw(@steel, 100)
    stock_raw(@bolt, 10) # 5개 생산에 20 필요

    assert_raises(Inventory::InsufficientStock) do
      Inventory::Backflush.call(work_order: @wo, produced_delta: 5, bucket_at: @bucket)
    end
    assert_equal 0, StockMove.where(move_type: %w[issue produce]).count
    assert_equal 100, Quant.find_by!(product_id: @steel.id, location_id: Location.find_by!(code: "line_side").id).qty
  end
end
