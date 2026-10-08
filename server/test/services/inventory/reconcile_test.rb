require "test_helper"

class Inventory::ReconcileTest < ActiveSupport::TestCase
  setup do
    @product = Product.create!(sku: "RAW-1", name: "강판", uom: "kg", kind: "raw")
    @receiving = Location.find_by!(code: "receiving")
    Inventory::Move.call(product: @product, lot: nil, from: Location.find_by!(code: "supplier"), to: @receiving,
                         qty: 10, move_type: "receive", ref: nil, idempotency_key: "rec-recv")
  end

  test "정상 이동만 있으면 불일치가 없다" do
    assert_equal [], Inventory::Reconcile.call
  end

  test "quants 를 몰래 바꾸면 해당 위치가 불일치로 잡힌다" do
    Quant.where(product_id: @product.id, location_id: @receiving.id).update_all(qty: 7)

    mismatches = Inventory::Reconcile.call

    assert_equal 1, mismatches.size
    row = mismatches.first
    assert_equal [@product.id, nil, @receiving.id], row.values_at(:product_id, :lot_id, :location_id)
    assert_equal [7, 10, -3], [row[:quant_qty], row[:ledger_qty], row[:diff]].map(&:to_i)
  end
end
