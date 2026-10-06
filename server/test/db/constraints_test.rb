require "test_helper"

# 모델 검증을 거치지 않고 SQL 로 직접 넣어 DB 제약만 시험한다.
class ConstraintsTest < ActiveSupport::TestCase
  setup do
    @m1 = Machine.create!(code: "M1", name: "절단기")
    @m2 = Machine.create!(code: "M2", name: "조립기")
    @order1 = WorkOrder.create!(code: "WO-1", machine: @m1, product: "브래킷", target_qty: 100)
    @order2 = WorkOrder.create!(code: "WO-2", machine: @m2, product: "브래킷", target_qty: 100)
  end

  # 제약 위반은 PG 트랜잭션을 중단시키므로 세이브포인트로 감싸 테스트 트랜잭션을 살린다.
  def assert_db_rejects(constraint, &block)
    error = assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.transaction(requires_new: true, &block)
    end
    assert_match(/#{constraint}/, error.message)
  end

  def insert_event(machine_id:, work_order_id:, machine_version: 0)
    ProductionEvent.insert!({ machine_id: machine_id, work_order_id: work_order_id,
                              bucket_start: Time.utc(2026, 10, 7, 0, 0, 0), bucket_end: Time.utc(2026, 10, 7, 0, 0, 10),
                              good_qty: 1, defect_qty: 0, machine_version: machine_version })
  end

  test "machines.version 은 음수가 될 수 없다" do
    assert_db_rejects("machines_version_check") { Machine.where(id: @m1.id).update_all(version: -1) }
  end

  test "commands.base_version 은 음수가 될 수 없다" do
    row = { idempotency_key: SecureRandom.uuid, machine_id: @m1.id, kind: "start", base_version: -1,
            created_at: Time.current }
    assert_db_rejects("commands_base_version_check") { Command.insert!(row) }
  end

  test "work_orders.produced_qty 는 음수가 될 수 없다" do
    assert_db_rejects("work_orders_produced_qty_check") { WorkOrder.where(id: @order1.id).update_all(produced_qty: -1) }
  end

  test "production_events.machine_version 은 음수가 될 수 없다" do
    assert_db_rejects("production_events_machine_version_check") do
      insert_event(machine_id: @m1.id, work_order_id: @order1.id, machine_version: -1)
    end
  end

  test "다른 기계의 작업지시를 가리키는 이벤트는 DB 가 막는다" do
    assert_db_rejects("fk_production_events_work_order_machine") do
      insert_event(machine_id: @m1.id, work_order_id: @order2.id)
    end
  end

  test "같은 기계의 작업지시를 가리키는 이벤트는 들어간다" do
    insert_event(machine_id: @m1.id, work_order_id: @order1.id)

    assert_equal 1, ProductionEvent.where(machine_id: @m1.id, work_order_id: @order1.id).count
  end
end
