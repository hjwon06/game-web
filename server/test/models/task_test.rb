require "test_helper"

class TaskTest < ActiveSupport::TestCase
  setup do
    Resource.ensure_defaults!
    @product = Product.create!(sku: "RAW-T1", name: "작업용 강판", uom: "ea", kind: "raw")
    @forklift = Resource.find_by!(code: "FORK-01")
    @receiving = Location.find_by!(code: "receiving")
    @bin = Location.find_by!(code: "RAW-A-01-01")
  end

  def build_task(**over)
    { kind: "putaway", resource: @forklift, product: @product, qty: 100, from_location: @receiving, to_location: @bin,
      planned_at: Time.current }.merge(over)
  end

  def create_task(**over) = Task.create!(build_task(**over))

  def a_stock_move(key)
    Inventory::Move.call(product: @product, lot: nil, from: "supplier", to: "receiving", qty: 1, move_type: "receive",
                         ref: nil, idempotency_key: key)
  end

  def assert_db_rejects(error = ActiveRecord::StatementInvalid, &block)
    assert_raises(error) { Task.transaction(requires_new: true, &block) }
  end

  test "seq 는 생성과 상태 변경마다 전역으로 증가한다" do
    t1 = create_task
    s_planned = t1.reload.seq
    t1.update!(status: "started", started_at: Time.current)
    s_started = t1.reload.seq
    t1.update!(status: "done", finished_at: Time.current)
    s_done = t1.reload.seq

    t2 = create_task
    s_other = t2.reload.seq

    assert_operator s_planned, :<, s_started
    assert_operator s_started, :<, s_done
    assert_operator s_done, :<, s_other
  end

  test "update_all 이나 raw SQL 로 상태를 바꿔도 seq 가 새로 배정된다 (앱 콜백이 아니라 DB 트리거)" do
    t = create_task
    before = t.reload.seq
    Task.where(id: t.id).update_all(status: "cancelled")
    after = t.reload.seq
    assert_operator after, :>, before

    ActiveRecord::Base.connection.execute("UPDATE tasks SET qty = 7 WHERE id = #{t.id.to_i}")
    assert_operator t.reload.seq, :>, after
  end

  test "seq 를 직접 넣어도 트리거가 덮어쓴다 (소비자가 믿는 값은 항상 시퀀스)" do
    t = create_task(seq: 1)
    assert_operator t.reload.seq, :>, 1
  end

  test "stock_move_id 는 한 번만 쓸 수 있다 (unique)" do
    move = a_stock_move("task-uq-1")
    create_task(status: "done", started_at: 2.minutes.ago, finished_at: 1.minute.ago, stock_move: move)

    assert_db_rejects(ActiveRecord::RecordNotUnique) do
      create_task(status: "done", started_at: 2.minutes.ago, finished_at: 1.minute.ago, stock_move: move)
    end
  end

  test "stock_move 는 done 일 때만 붙고, started/done 은 시각이 있어야 한다 (DB CHECK)" do
    move = a_stock_move("task-chk-1")
    planned = create_task
    assert_db_rejects { Task.where(id: planned.id).update_all(stock_move_id: move.id) }

    assert_db_rejects { Task.where(id: planned.id).update_all(status: "started") }
    assert_db_rejects { Task.where(id: planned.id).update_all(status: "done", started_at: Time.current) }
  end

  test "kind·status·qty·같은 위치는 모델과 DB 둘 다 거부한다" do
    assert_not Task.new(build_task(kind: "teleport")).valid?
    assert_not Task.new(build_task(status: "paused")).valid?
    assert_not Task.new(build_task(qty: 0)).valid?

    assert_db_rejects { Task.new(build_task(kind: "teleport")).save!(validate: false) }
    assert_db_rejects { Task.new(build_task(status: "paused")).save!(validate: false) }
    assert_db_rejects { Task.new(build_task(qty: 0)).save!(validate: false) }
    assert_db_rejects { Task.new(build_task(to_location: @receiving)).save!(validate: false) }
  end

  test "자원은 비워 두고 계획만 만들 수 있다" do
    assert create_task(resource: nil).persisted?
  end
end
