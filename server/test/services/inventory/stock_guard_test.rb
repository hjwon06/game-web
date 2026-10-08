require "test_helper"

# 재고가 모자란 issue/ship 은 거부되고, 거부된 요청은 원장도 현재고도 바꾸지 않는다. 물리 위치는 마이너스가 될 수 없다.
class Inventory::StockGuardTest < ActiveSupport::TestCase
  setup do
    @steel = Product.create!(sku: "RAW-GUARD", name: "가드 자재", uom: "ea", kind: "raw")
    @fg = Product.create!(sku: "FG-GUARD", name: "가드품", uom: "ea", kind: "fg")
    @lot = Lot.create!(product: @fg, lot_no: "LOT-GUARD")
  end

  def move(product, lot, from, to, qty, type, key)
    Inventory::Move.call(product: product, lot: lot, from: from, to: to, qty: qty, move_type: type, ref: nil,
                         idempotency_key: key)
  end

  def qty(product, code, lot: nil)
    Quant.where(product_id: product.id, lot_id: lot&.id, location_id: Location.find_by!(code: code).id).sum(:qty)
  end

  def physical_negative_count
    Quant.joins(:location).where(locations: { kind: "physical" }).where("quants.qty < 0").count
  end

  test "자재창고 재고보다 많이 issue 하면 거부되고 아무것도 안 바뀐다" do
    move(@steel, nil, "supplier", "receiving", 5, "receive", "g-recv")
    move(@steel, nil, "receiving", "raw_store", 5, "putaway", "g-put")

    assert_raises(Inventory::InsufficientStock) { move(@steel, nil, "raw_store", "production", 6, "issue", "g-issue") }

    assert_equal 0, StockMove.where(idempotency_key: "g-issue").count
    assert_equal [5, 0], [qty(@steel, "raw_store"), qty(@steel, "production")].map(&:to_i)
    assert_equal 0, physical_negative_count
  end

  test "재고 없는 품목을 issue 해도 거부된다(빈 quant 행이 남아도 0)" do
    assert_raises(Inventory::InsufficientStock) { move(@steel, nil, "raw_store", "production", 1, "issue", "g-empty") }
    assert_equal 0, StockMove.count
    assert_equal 0, physical_negative_count
  end

  test "완제품창고 재고보다 많이 ship 하면 거부되고 수주 상태도 그대로다" do
    move(@fg, @lot, "production", "qc", 3, "produce", "g-prod")
    move(@fg, @lot, "qc", "fg_store", 3, "qc_pass", "g-pass")
    order = SalesOrder.create!(so_no: "SO-GUARD", customer: "가드고객")
    line = SalesOrderLine.create!(sales_order: order, product: @fg, ordered_qty: 10)

    assert_raises(Inventory::InsufficientStock) do
      Inventory::Ship.call(sales_order_line: line, lot: @lot, qty: 5, idempotency_key: "g-ship")
    end

    assert_equal 0, StockMove.where(move_type: "ship").count
    assert_equal "open", order.reload.status
    assert_equal 3, qty(@fg, "fg_store", lot: @lot)
    assert_equal 0, physical_negative_count
  end

  test "다른 로트 재고로는 ship 할 수 없다(재고는 로트별이다)" do
    other = Lot.create!(product: @fg, lot_no: "LOT-GUARD-2")
    move(@fg, @lot, "production", "qc", 5, "produce", "g-prod-2")
    move(@fg, @lot, "qc", "fg_store", 5, "qc_pass", "g-pass-2")

    assert_raises(Inventory::InsufficientStock) { move(@fg, other, "fg_store", "customer", 1, "ship", "g-ship-2") }
    assert_equal 5, qty(@fg, "fg_store", lot: @lot)
  end

  test "공급처 같은 가상 위치는 마이너스가 되고 물리 위치만 막는다" do
    move(@steel, nil, "supplier", "receiving", 7, "receive", "g-virtual")

    assert_equal(-7, qty(@steel, "supplier"))
    assert_equal 0, physical_negative_count
  end

  test "DB 트리거가 물리 위치 마이너스를 raw SQL UPDATE 로도 막는다" do
    move(@steel, nil, "supplier", "receiving", 2, "receive", "g-check")
    quant = Quant.find_by!(product_id: @steel.id, location_id: Location.find_by!(code: "receiving").id)

    error = assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.transaction(requires_new: true) do
        ActiveRecord::Base.connection.execute("UPDATE quants SET qty = -1 WHERE id = #{quant.id.to_i}")
      end
    end
    assert_match(/quants_physical_non_negative/, error.message)
    assert_equal 2, quant.reload.qty
  end

  test "물리 위치 quant 를 음수로 INSERT 해도 막히고, 우회용 플래그 컬럼은 없다" do
    receiving = Location.find_by!(code: "receiving")
    assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.transaction(requires_new: true) do
        ActiveRecord::Base.connection.execute(
          "INSERT INTO quants (product_id, location_id, qty, created_at, updated_at) " \
          "VALUES (#{@steel.id}, #{receiving.id}, -1, now(), now())"
        )
      end
    end
    assert_not Quant.column_names.include?("negative_allowed"), "우회용 플래그 컬럼이 남아 있다"
  end
end
