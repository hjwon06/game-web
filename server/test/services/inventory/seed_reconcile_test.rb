require "test_helper"
require "rake"

# 재고 시드(rake inventory:seed) 결과 검증: 규모, 단위, 부분 출하 1건, 재실행 안전, Reconcile 불일치 0.
class Inventory::SeedReconcileTest < ActiveSupport::TestCase
  # db/seeds.rb 의 활성 작업지시 4건과 같은 모양(품목명 문자열만 넘기고 product_id 는 모델이 채운다)
  WORK_ORDERS = [["WO-1001", "브래킷 A"], ["WO-1002", "하우징 B"], ["WO-1003", "플레이트 C"], ["WO-1004", "샤프트 D"]].freeze

  setup do
    machine = Machine.create!(code: "SD1", name: "시드기")
    WORK_ORDERS.each { |code, name| WorkOrder.create!(code: code, machine: machine, product: name, target_qty: 100) }
    Rails.application.load_tasks unless Rake::Task.task_defined?("inventory:seed")
  end

  def seed!
    Rake::Task["inventory:seed"].reenable
    capture_io { Rake::Task["inventory:seed"].invoke }
  end

  def counts
    [Product, Lot, BomLine, SalesOrder, SalesOrderLine, StockMove, Quant, Inspection].to_h { |m| [m.name, m.count] }
  end

  test "시드 후 quants 와 원장의 불일치가 0이다" do
    seed!
    assert_equal [], Inventory::Reconcile.call
    assert_operator StockMove.count, :>, 100 # 빈 시드가 불일치 0 으로 통과하는 것을 막는다
  end

  test "규모: 품목 6~8종 ea 단위, 로트 20~30, 수주 10건, BOM 연결" do
    seed!
    assert_includes 6..8, Product.count
    assert_equal ["ea"], Product.distinct.pluck(:uom)
    assert_equal 4, Product.where(kind: "fg").count
    assert_includes 3..4, Product.where(kind: "raw").count
    assert_includes 20..30, Lot.count
    assert_equal 10, SalesOrder.count
    assert_equal Product.where(kind: "fg").pluck(:id).sort, BomLine.distinct.pluck(:product_id).sort
  end

  test "작업지시가 만든 품목을 재사용하고 work_orders.product_id 가 그대로다" do
    ids = WorkOrder.order(:code).pluck(:product_id)
    seed!
    assert_equal ids, WorkOrder.order(:code).pluck(:product_id)
    assert_equal 4, Product.where(kind: "fg").count
  end

  test "수주 중 정확히 1건이 partial 이고 100 주문 중 70 출하다" do
    seed!
    assert_equal({ "open" => 2, "partial" => 1, "done" => 7 }, SalesOrder.group(:status).count)

    partial = SalesOrder.find_by!(status: "partial")
    line = partial.lines.sole
    shipped = StockMove.where(move_type: "ship", ref_type: "SalesOrderLine", ref_id: line.id).sum(:qty)
    assert_equal [100, 70], [line.ordered_qty.to_i, shipped.to_i]
  end

  test "모든 재고 변동이 원장에 있다: 물리 위치 마이너스 0, 이동 유형은 9종 전부다(feed·pick 포함)" do
    seed!
    assert_equal 0, Quant.joins(:location).where(locations: { kind: "physical" }).where("quants.qty < 0").count
    assert_empty StockMove.distinct.pluck(:move_type) - StockMove::MOVE_TYPES
    assert_equal StockMove::MOVE_TYPES.sort, StockMove.distinct.pluck(:move_type).sort
  end

  test "끝나지 않은 작업지시의 모든 완제품에 raw 자재 1~2개 BOM 이 붙고, 재실행해도 같다" do
    machine = Machine.create!(code: "SD2", name: "시드기 2")
    WorkOrder.create!(code: "WO-9001", machine: machine, product: "기어 Z", target_qty: 100, status: "active")
    WorkOrder.create!(code: "WO-9002", machine: machine, product: "커버 Y", target_qty: 100, status: "queued")
    WorkOrder.create!(code: "WO-9003", machine: machine, product: "끝난 품목", target_qty: 100, status: "done")

    seed!
    boms = BomLine.all.map { |b| [b.product_id, b.component_id, b.qty_per] }.sort

    WorkOrder.where.not(status: "done").includes(:item).each do |wo|
      lines = BomLine.where(product_id: wo.product_id)
      # 기본 시드가 이미 BOM 을 준 품목(예: 샤프트 D 3줄)은 보강 대상이 아니다. 비어 있지만 않으면 된다
      assert_operator lines.count, :>=, 1, "#{wo.item.name} BOM"
      assert_equal ["raw"], lines.map { |l| l.component.kind }.uniq
      assert_equal ["ea"], lines.map { |l| l.component.uom }.uniq
    end
    assert_equal 0, BomLine.where(product_id: Product.find_by!(name: "끝난 품목").id).count, "끝난 지시 품목은 건드리지 않는다"
    assert_equal 3, Product.where(kind: "raw").count, "새 자재 품목을 만들지 않았다"

    seed!
    seed!
    assert_equal boms, BomLine.all.map { |b| [b.product_id, b.component_id, b.qty_per] }.sort
    assert_equal [], Inventory::Reconcile.call
  end

  test "재실행해도 아무것도 늘지 않는다(2회 더)" do
    seed!
    first = counts
    seed!
    seed!

    assert_equal first, counts
    assert_equal [], Inventory::Reconcile.call
  end
end
