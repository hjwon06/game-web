require "test_helper"

# Ops::Plan 의 계획 시점 재검증(R0)이 동시 계획에서도 지켜지는지 본다. 트랜잭션 테스트를 끄고 스레드마다 별도 커넥션을 쓴다.
#   1) 두 스레드가 같은 재고 행에서 각자 가용보다 작지만 합치면 넘치는 양을 계획하면 하나만 성공하고 하나는 InsufficientStock.
#   2) 두 스레드가 같은 칸으로 각자 들어갈 수는 있지만 합치면 용량을 넘는 양을 계획하면 하나만 성공하고 하나는 CapacityExceeded.
# Ops::Plan 의 verify! 호출을 지우면 둘 다 성공해 이 테스트는 실패해야 한다.
class ConcurrencyPlanTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  ROUNDS = 10
  JOIN_SECONDS = 15
  BIN = "RAW-A-01-01".freeze

  WIPE_SQL = "TRUNCATE tasks, reservations, cycle_counts, stock_moves, quants, lots, products RESTART IDENTITY CASCADE".freeze

  setup do
    assert_trigger_enabled
    wipe
    Resource.ensure_defaults!
    Ops::Plan.reseed!(51)
    @product = Product.create!(sku: "RAW-PLN", name: "동시계획 자재", uom: "ea", kind: "raw")
    @seq = 0
  end

  teardown { wipe }

  # 원장은 TRUNCATE 가 막혀 있어 트리거를 잠시 끈다. 해제·TRUNCATE·재활성화를 한 트랜잭션에 묶어 중간 실패에도 해제 상태로 남지 않는다.
  def wipe
    conn = ActiveRecord::Base.connection
    conn.transaction do
      conn.execute("ALTER TABLE stock_moves DISABLE TRIGGER stock_moves_no_truncate")
      conn.execute(WIPE_SQL)
      conn.execute("ALTER TABLE stock_moves ENABLE TRIGGER stock_moves_no_truncate")
    end
  end

  def assert_trigger_enabled
    state = ActiveRecord::Base.connection.select_value("SELECT tgenabled FROM pg_trigger WHERE tgname = 'stock_moves_no_truncate'")
    assert_equal "O", state, "stock_moves_no_truncate 트리거가 꺼진 채 남아 있다"
  end

  def mv(from, to, qty, type)
    Inventory::Move.call(product: @product, lot: nil, from: from, to: to, qty: qty, move_type: type, ref: nil,
                         idempotency_key: "cplan-#{@seq += 1}")
  end

  # 스레드 둘이 start 신호와 함께 같은 블록을 실행하고 결과(작업 또는 예외)를 돌려준다.
  def race(count = 2, &job)
    start = Queue.new
    threads = Array.new(count) do
      Thread.new do
        Thread.current.report_on_exception = false
        ActiveRecord::Base.connection_pool.with_connection do
          start.pop
          job.call
        rescue StandardError => e
          e
        end
      end
    end
    count.times { start << true }
    threads.map { |t| t.join(JOIN_SECONDS) ? t.value : flunk("스레드가 #{JOIN_SECONDS}초 안에 끝나지 않았다") }
  end

  def reset_tasks
    Task.delete_all # reservations 는 DB 의 on_delete cascade 가 따라 지운다
  end

  test "같은 재고를 동시에 계획하면 하나만 성공하고 하나는 InsufficientStock 이다" do
    mv("supplier", "receiving", 500, "receive")
    mv("receiving", BIN, 500, "putaway")

    ROUNDS.times do |round|
      results = race { Ops::Plan.call(kind: "feed", product: @product, lot: nil, qty: 300, from: BIN, to: "line_side", ref: nil, earliest_at: Time.current) }

      assert_equal 1, results.count { |r| r.is_a?(Task) }, "라운드 #{round}: 성공은 정확히 1건 #{results.map(&:class)}"
      failures = results.grep(StandardError)
      assert_equal [Inventory::InsufficientStock], failures.map(&:class), "라운드 #{round}: 실패는 InsufficientStock"
      assert_equal 1, Task.where(kind: "feed", status: "planned").count
      assert_equal 300, Reservation.active.sum(:qty).to_i, "예약은 성공한 작업 몫만"
      assert_equal 500, Quant.where(product_id: @product.id, location: Location.find_by!(code: BIN)).sum(:qty).to_i, "계획은 재고를 움직이지 않는다"
      reset_tasks
    end
  end

  test "같은 칸에 동시에 적치를 계획하면 용량 초과분은 CapacityExceeded 이다" do
    capacity = Location.find_by!(code: BIN).capacity_units.to_i
    qty = (capacity * 3) / 4 # 하나는 들어가지만 둘이면 용량을 넘는다
    assert_operator qty, :<, capacity
    assert_operator qty * 2, :>, capacity
    mv("supplier", "receiving", qty * 2, "receive") # 가용 재고는 둘 다 감당한다. 막는 것은 칸 용량뿐이다.

    ROUNDS.times do |round|
      results = race { Ops::Plan.call(kind: "putaway", product: @product, lot: nil, qty: qty, from: "receiving", to: BIN, ref: nil, earliest_at: Time.current) }

      assert_equal 1, results.count { |r| r.is_a?(Task) }, "라운드 #{round}: 성공은 정확히 1건 #{results.map(&:class)}"
      assert_equal [Inventory::CapacityExceeded], results.grep(StandardError).map(&:class), "라운드 #{round}: 실패는 CapacityExceeded"
      assert_equal qty, Task.where(to_location_id: Location.find_by!(code: BIN).id, status: "planned").sum(:qty).to_i, "들어오는 중 합이 용량 안"
      reset_tasks
    end
  end
end
