require "test_helper"

class WorkOrderTest < ActiveSupport::TestCase
  setup do
    @machine = Machine.create!(code: "M1", name: "절단기")
    @product = Product.create!(sku: "T-BRACKET-A", name: "브래킷 A", uom: "ea", kind: "fg")
  end

  def insert_order(code, status: "active", target_qty: 100)
    WorkOrder.transaction(requires_new: true) do
      WorkOrder.insert_all!([{ code: code, machine_id: @machine.id, product: "브래킷 A", product_id: @product.id,
                               target_qty: target_qty,
                               status: status, created_at: Time.current, updated_at: Time.current }])
    end
  end

  test "기계당 active 2건은 DB 부분 유니크 인덱스가 막는다" do
    insert_order("WO-1")
    assert_raises(ActiveRecord::RecordNotUnique) { insert_order("WO-2") }
  end

  test "active 가 아닌 작업지시는 여러 건 들어간다" do
    insert_order("WO-1")
    assert_difference("WorkOrder.count", 2) do
      insert_order("WO-2", status: "queued")
      insert_order("WO-3", status: "done")
    end
  end

  test "target_qty 0 이하는 DB CHECK 가 막는다" do
    assert_raises(ActiveRecord::CheckViolation) { insert_order("WO-1", target_qty: 0) }
  end

  test "잘못된 status 는 DB CHECK 가 막는다" do
    assert_raises(ActiveRecord::CheckViolation) { insert_order("WO-1", status: "paused") }
  end
end
