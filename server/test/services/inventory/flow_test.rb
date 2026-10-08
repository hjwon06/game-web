require "test_helper"

# 수주 1건이 입고 → 적치 → 출고 → 생산 → 검사 → 출하까지 이어질 때 단계마다 위치별 quants 가 기대값인지 본다.
# 생산·검사·출하는 실제 파이프라인 서비스(Backflush, Inspect, Ship)에 실제 모양의 입력을 넣는다.
class Inventory::FlowTest < ActiveSupport::TestCase
  setup do
    @steel = Product.create!(sku: "RAW-FLOW", name: "플로우 강판", uom: "ea", kind: "raw")
    @fg = Product.create!(sku: "FG-FLOW", name: "플로우품", uom: "ea", kind: "fg")
    BomLine.create!(product: @fg, component: @steel, qty_per: 2)
    machine = Machine.create!(code: "FL1", name: "플로우기")
    @work_order = WorkOrder.create!(code: "WO-FLOW", machine: machine, product: "플로우품", target_qty: 10)
    order = SalesOrder.create!(so_no: "SO-FLOW", customer: "플로우고객")
    @line = SalesOrderLine.create!(sales_order: order, product: @fg, ordered_qty: 9)
    @order = order
  end

  def qty(product, code)
    Quant.where(product_id: product.id, location_id: Location.find_by!(code: code).id).sum(:qty)
  end

  def raw_move(from, to, amount, type, key)
    Inventory::Move.call(product: @steel, lot: nil, from: from, to: to, qty: amount, move_type: type, ref: nil,
                         idempotency_key: key)
  end

  test "수주 1건이 receive→putaway→feed→issue→produce→qc_pass→pick→ship 까지 흐르고 단계마다 위치별 재고가 맞다" do
    assert_equal @fg.id, @work_order.product_id

    # receive: 공급처는 가상이라 마이너스, 입고대 +100
    raw_move("supplier", "receiving", 100, "receive", "flow-recv")
    assert_equal [-100, 100], [qty(@steel, "supplier"), qty(@steel, "receiving")].map(&:to_i)

    # putaway
    raw_move("receiving", "raw_store", 100, "putaway", "flow-putaway")
    assert_equal [0, 100], [qty(@steel, "receiving"), qty(@steel, "raw_store")].map(&:to_i)

    # feed: 자재창고 → 라인 공급대
    raw_move("raw_store", "line_side", 100, "feed", "flow-feed")
    assert_equal [0, 100], [qty(@steel, "raw_store"), qty(@steel, "line_side")].map(&:to_i)

    # issue + produce: 완제품 10개 = 강판 20개. 자재는 line_side 에서 나간다
    moves = Inventory::Backflush.call(work_order: @work_order, produced_delta: 10, bucket_at: Time.utc(2026, 10, 8, 9, 0, 0))
    assert_equal %w[issue produce], moves.map(&:move_type)
    assert_equal [80, 20], [qty(@steel, "line_side"), qty(@steel, "production")].map(&:to_i)
    assert_equal [-10, 10], [qty(@fg, "production"), qty(@fg, "qc")].map(&:to_i)

    # qc_pass(9) + qc_fail(1)
    lot = Lot.find_by!(product_id: @fg.id, lot_no: @work_order.code)
    Inventory::Inspect.call(lot: lot, work_order: @work_order, pass_qty: 9, fail_qty: 1, idempotency_key: "flow-qc")
    assert_equal [0, 9, 1], %w[qc fg_store scrap].map { |c| qty(@fg, c).to_i }
    assert_equal 2, Inspection.where(lot_id: lot.id).count

    # pick 9: 완제품창고 → 출하대
    Inventory::Move.call(product: @fg, lot: lot, from: "fg_store", to: "shipping", qty: 9, move_type: "pick", ref: nil,
                         idempotency_key: "flow-pick")
    assert_equal [0, 9], [qty(@fg, "fg_store"), qty(@fg, "shipping")].map(&:to_i)

    # ship 9 = 주문량 전부: 출하대 → 고객
    Inventory::Ship.call(sales_order_line: @line, lot: lot, qty: 9, idempotency_key: "flow-ship")
    assert_equal [0, 9], [qty(@fg, "shipping"), qty(@fg, "customer")].map(&:to_i)
    assert_equal "done", @order.reload.status

    # 이동 유형 9종이 모두 한 번 이상 나왔다
    assert_equal StockMove::MOVE_TYPES.sort, StockMove.distinct.pluck(:move_type).sort
    assert_equal [], Inventory::Reconcile.call
  end
end
