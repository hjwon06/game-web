require "test_helper"

# 지게차 큐 우선순위(2단계-⑥j): feed 는 계획된(planned) 덜 급한 작업 앞에 끼어들고, 밀린 작업은 같은 트랜잭션에서 뒤로 미뤄진다.
class OpsPlanPriorityTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers
  T0 = Time.utc(2026, 10, 8, 12, 0, 0)

  setup do
    travel_to T0
    Ops::Plan.reseed!(11)
    @steel = Product.create!(sku: "RAW-PR", name: "강판", uom: "ea", kind: "raw")
    @fg = Product.create!(sku: "FG-PR", name: "브래킷", uom: "ea", kind: "fg")
    @a, @b = Resource.where(kind: "forklift").order(:id).to_a
    assert_equal 2, Resource.where(kind: "forklift").count
  end

  teardown { travel_back }

  def make(resource, status:, from_s:, secs:, priority: 50, kind: "putaway")
    start = T0 + from_s
    Task.create!(kind: kind, status: status, resource: resource, product: @fg, qty: 1, priority: priority,
                 from_location: Location.find_by!(code: "receiving"), to_location: Location.find_by!(code: "qc"),
                 planned_at: start, started_at: (start if status == "started"), expected_finish_at: start + secs)
  end

  # 다른 지게차를 한 시간 뒤까지 붙잡아 새 작업이 @a 로만 가게 한다.
  def block_b = make(@b, status: "started", from_s: -10, secs: 3600)

  def plan(kind, product: @steel, priority_from: "supplier", to: "production")
    Ops::Plan.call(kind: kind, product: product, lot: nil, qty: 1, from: priority_from, to: to, ref: nil, earliest_at: T0)
  end

  test "기본 priority 는 종류별로 들어간다" do
    assert_equal 10, plan("feed").priority
    assert_equal 30, plan("putaway", to: "receiving").priority
    assert_equal 40, plan("putaway", product: @fg, to: "receiving").priority
    assert_equal 50, plan("unload", to: "receiving").priority
  end

  test "feed 는 started 바로 뒤로 들어가고 planned putaway 5건은 feed 소요만큼 밀린다" do
    block_b
    running = make(@a, status: "started", from_s: -25, secs: 45) # now+20 에 끝난다
    queued = 5.times.map { |i| make(@a, status: "planned", from_s: 20 + 45 * i, secs: 45, priority: 40) }
    before = queued.map { |t| [t.planned_at, t.expected_finish_at] }
    running.reload # seq 는 DB 트리거(tasks_seq)가 채운다 — 다시 읽어야 값이 있다
    run_before = [running.planned_at, running.started_at, running.expected_finish_at, running.seq]

    feed = plan("feed")

    assert_equal @a, feed.resource
    assert_equal running.expected_finish_at, feed.planned_at
    dur = feed.expected_finish_at - feed.planned_at
    queued.each_with_index do |t, i|
      t.reload
      assert_in_delta before[i][0] + dur, t.planned_at, 0.001
      assert_in_delta before[i][1] + dur, t.expected_finish_at, 0.001
    end
    assert_in_delta feed.expected_finish_at, queued.first.planned_at, 0.001
    queued.each_cons(2) { |x, y| assert_operator x.expected_finish_at, :<=, y.planned_at }
    running.reload
    assert_equal run_before, [running.planned_at, running.started_at, running.expected_finish_at, running.seq]
  end

  test "같은 priority 끼리는 FIFO 다" do
    block_b
    late = make(@a, status: "planned", from_s: 0, secs: 45, priority: 40)
    first = plan("feed")
    second = plan("feed")

    assert_equal @a, first.resource
    assert_equal @a, second.resource
    assert_in_delta first.expected_finish_at, second.planned_at, 0.001
    assert_operator late.reload.planned_at, :>=, second.expected_finish_at
  end

  test "더 급한 planned 뒤에는 밀지 않고 그 뒤에 붙는다" do
    block_b
    urgent = make(@a, status: "planned", from_s: 0, secs: 30, priority: 5)
    lazy = make(@a, status: "planned", from_s: 30, secs: 45, priority: 40)
    feed = plan("feed")

    assert_in_delta urgent.expected_finish_at, feed.planned_at, 0.001
    assert_in_delta feed.expected_finish_at, lazy.reload.planned_at, 0.001
    assert_equal T0, urgent.reload.planned_at
  end

  test "밀린 작업은 작업 스트림(seq)에 다시 나온다" do
    block_b
    queued = 3.times.map { |i| make(@a, status: "planned", from_s: 45 * i, secs: 45, priority: 40) }
    cursor = Task.maximum(:seq)

    plan("feed")

    again = Task.where("seq > ?", cursor).pluck(:id)
    queued.each { |t| assert_includes again, t.id }
  end

  test "자원이 둘이면 삽입 후 시작 시각이 더 이른 쪽을 고른다" do
    make(@a, status: "started", from_s: -10, secs: 110) # now+100 에 빈다, 대기 없음
    make(@b, status: "started", from_s: -40, secs: 50)  # now+10 에 끝난다
    3.times { |i| make(@b, status: "planned", from_s: 10 + 45 * i, secs: 45, priority: 40) } # 끝에 붙으면 now+145

    feed = plan("feed")

    assert_equal @b, feed.resource
    assert_equal T0 + 10, feed.planned_at
  end

  test "queue_seconds 는 우선순위와 상관없이 마지막 작업 끝까지다" do
    make(@a, status: "planned", from_s: 0, secs: 200, priority: 40)
    make(@b, status: "planned", from_s: 0, secs: 300, priority: 40)
    assert_equal 200.0, Ops::Plan.queue_seconds("forklift", now: T0)
  end
end
