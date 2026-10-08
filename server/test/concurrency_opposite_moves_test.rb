require "test_helper"

# location_id 오름차순으로 잠그는 이동(putaway, qc_pass)과 내림차순으로 흐르는 이동(issue, ship)이
# 같은 위치를 두고 동시에 와도 교착 없이 끝나고 현재고가 원장과 맞아야 한다.
# 허용 경로에 같은 위치쌍의 역방향 이동은 없다. 그래서 "반대 방향"은 공유 위치 하나(raw_store, fg_store)에서
# from→to 의 id 대소가 서로 반대인 두 이동으로 만든다. Move 가 잠금 순서를 정렬하지 않으면 여기서 Deadlocked 가 난다.
class ConcurrencyOppositeMovesTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  ROUNDS = 20
  JOIN_SECONDS = 15

  WIPE_SQL = "TRUNCATE inspections, stock_moves, quants, lots, bom_lines, sales_order_lines, sales_orders, " \
             "work_orders, products RESTART IDENTITY CASCADE".freeze

  setup do
    assert_trigger_enabled
    wipe
    @product = Product.create!(sku: "RAW-OPP", name: "반대방향 자재", uom: "ea", kind: "raw")
  end

  teardown { wipe }

  # 원장은 UPDATE/DELETE/TRUNCATE 가 전부 막혀 있어 커밋된 데이터를 지울 방법이 TRUNCATE 트리거를 잠시 끄는 것뿐이다.
  # 트리거 해제·TRUNCATE·재활성화를 한 트랜잭션에 묶어(PostgreSQL DDL 은 트랜잭션이다) 중간 실패가 나도 해제 상태로 남지 않는다.
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

  def mv(from, to, qty, type, key)
    Inventory::Move.call(product: @product, lot: nil, from: from, to: to, qty: qty, move_type: type, ref: nil,
                         idempotency_key: key)
  end

  def qty(code)
    Quant.where(product_id: @product.id, location_id: Location.find_by!(code: code).id).sum(:qty).to_i
  end

  # 스레드는 inbox 에서 작업을 받고, start 큐에서 출발 신호를 받아 실행한 뒤 결과(이동 또는 예외)를 results 에 넣는다.
  def worker(inbox, start, results)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        while (job = inbox.pop)
          start.pop
          outcome =
            begin
              job.call
            rescue StandardError => e
              e
            end
          results << outcome
        end
      end
    end
  end

  # job_a, job_b 는 라운드 번호를 받아 이동을 만드는 람다다. 매 라운드 두 작업을 거의 동시에 출발시킨다.
  def race(job_a, job_b)
    inboxes = Array.new(2) { Queue.new }
    start = Queue.new
    results = Queue.new
    threads = inboxes.map { |inbox| worker(inbox, start, results) }
    threads.each { |t| t.report_on_exception = false }
    outcomes = []

    begin
      ROUNDS.times do |round|
        inboxes[0] << -> { job_a.call(round) }
        inboxes[1] << -> { job_b.call(round) }
        2.times { start << true }
        2.times { outcomes << (results.pop(timeout: JOIN_SECONDS) || flunk("이동이 #{JOIN_SECONDS}초 안에 끝나지 않았다")) }
      end
    ensure
      inboxes.each { |inbox| inbox << nil }
      threads.each do |t|
        t.join(JOIN_SECONDS)
      rescue StandardError
        nil # 본 단언 실패를 가리지 않는다
      end
    end

    errors = outcomes.grep(Exception).map { |e| "#{e.class}: #{e.message.lines.first}" }
    assert_empty errors, "예외(교착 포함)가 없어야 한다"
    assert_equal ROUNDS * 2, outcomes.grep(StockMove).size
  end

  def assert_consistent
    assert_equal [], Inventory::Reconcile.call
    assert_equal 0, Quant.joins(:location).where(locations: { kind: "physical" }).where("quants.qty < 0").count
  end

  test "putaway(receiving→raw_store)와 issue(raw_store→production)가 raw_store 를 두고 20회 동시에 와도 교착이 없다" do
    mv("supplier", "receiving", 200, "receive", "opp-seed-recv")
    mv("receiving", "raw_store", 100, "putaway", "opp-seed-put")

    race(->(i) { mv("receiving", "raw_store", 1, "putaway", "opp-put-#{i}") },
         ->(i) { mv("raw_store", "production", 1, "issue", "opp-issue-#{i}") })

    assert_equal [80, 100, 20], [qty("receiving"), qty("raw_store"), qty("production")]
    assert_consistent
  end

  test "qc_pass(qc→fg_store)와 ship(fg_store→customer)이 fg_store 를 두고 20회 동시에 와도 교착이 없다" do
    mv("production", "qc", 200, "produce", "opp-seed-prod")
    mv("qc", "fg_store", 100, "qc_pass", "opp-seed-pass")

    race(->(i) { mv("qc", "fg_store", 1, "qc_pass", "opp-pass-#{i}") },
         ->(i) { mv("fg_store", "customer", 1, "ship", "opp-ship-#{i}") })

    assert_equal [80, 100, 20], [qty("qc"), qty("fg_store"), qty("customer")]
    assert_consistent
  end
end
