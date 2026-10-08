require "test_helper"
require "rake"

class TaskPruneTest < ActiveSupport::TestCase
  setup do
    Resource.ensure_defaults!
    @product = Product.create!(sku: "RAW-PR", name: "정리용 강판", uom: "ea", kind: "raw")
    @receiving = Location.find_by!(code: "receiving")
    @bin = Location.find_by!(code: "RAW-A-01-01")
  end

  def make(status:, age_days:, **over)
    t = Task.create!({ kind: "putaway", product: @product, qty: 10, from_location: @receiving, to_location: @bin,
                       planned_at: age_days.days.ago - 1.hour, status: status }.merge(over))
    t
  end

  def make_done(age_days:, **over)
    make(status: "done", age_days: age_days, started_at: age_days.days.ago - 30.minutes, finished_at: age_days.days.ago, **over)
  end

  test "7일 지난 done 만 지우고 최근 done·진행 중·계획 작업은 남긴다" do
    old_done = make_done(age_days: 8)
    recent_done = make_done(age_days: 6)
    old_started = make(status: "started", age_days: 9, started_at: 9.days.ago)
    old_planned = make(status: "planned", age_days: 9)

    assert_equal 1, Task.prune!
    assert_not Task.exists?(old_done.id)
    assert Task.exists?(recent_done.id)
    assert Task.exists?(old_started.id)
    assert Task.exists?(old_planned.id)
  end

  test "cancelled 는 finished_at 이 없어도 updated_at 기준으로 지운다" do
    old_cancelled = make(status: "cancelled", age_days: 9)
    fresh_cancelled = make(status: "cancelled", age_days: 9)
    old_cancelled.update_columns(updated_at: 8.days.ago)

    assert_equal 1, Task.prune!
    assert_not Task.exists?(old_cancelled.id)
    assert Task.exists?(fresh_cancelled.id)
  end

  test "정확히 7일 안쪽 경계: 6일 23시간 전에 끝난 done 은 남는다" do
    t = make_done(age_days: 6)
    t.update_columns(finished_at: 6.days.ago - 23.hours)
    assert_equal 0, Task.prune!
    assert Task.exists?(t.id)
  end

  test "stock_moves 는 건드리지 않는다 — 지워진 작업이 가리키던 이동이 그대로 남는다" do
    move = Inventory::Move.call(product: @product, lot: nil, from: "supplier", to: "receiving", qty: 10,
                                move_type: "receive", ref: nil, idempotency_key: "prune-recv")
    make_done(age_days: 10, stock_move: move)
    moves_before = StockMove.count

    assert_equal 1, Task.prune!
    assert_equal moves_before, StockMove.count
    assert StockMove.exists?(move.id)
    assert_equal [], Inventory::Reconcile.call
  end

  test "rake task:prune 이 같은 일을 하고 건수를 출력한다" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task:prune")
    old = make_done(age_days: 8)
    keep = make_done(age_days: 1)

    out, = capture_io do
      Rake::Task["task:prune"].reenable
      Rake::Task["task:prune"].invoke
    end

    assert_match(/task:prune 1건 삭제/, out)
    assert_not Task.exists?(old.id)
    assert Task.exists?(keep.id)
  end
end
