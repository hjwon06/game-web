require "test_helper"

# location_id 오름차순으로 들어오는 이동(feed, pick)과 내림차순으로 나가는 이동(issue, ship)이
# 같은 위치를 두고 동시에 와도 교착 없이 끝나고 현재고가 원장과 맞아야 한다.
# 허용 경로에 같은 위치쌍의 역방향 이동은 없다. 그래서 "반대 방향"은 공유 위치 하나(line_side, shipping)에서
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

  def loc_id(code) = Location.find_by!(code: code).id

  test "feed(raw_store→line_side)와 issue(line_side→production)가 line_side 를 두고 20회 동시에 와도 교착이 없다" do
    # 두 이동이 line_side 를 두고 id 대소가 반대여야 이 시험이 의미가 있다(feed 는 오름차순, issue 는 내림차순).
    # id 는 테스트 워커 DB 마다 달라 대소를 단언하면 플래키하다(실측: line_side id=1). 대소와 무관하게
    # 같은 두 행(line_side 와 상대 위치)을 반대 방향에서 잡으므로 Move 의 정렬 잠금이 없으면 교착이 난다.

    mv("supplier", "receiving", 200, "receive", "opp-seed-recv")
    mv("receiving", "raw_store", 200, "putaway", "opp-seed-put")
    mv("raw_store", "line_side", 100, "feed", "opp-seed-feed")

    race(->(i) { mv("raw_store", "line_side", 1, "feed", "opp-feed-#{i}") },
         ->(i) { mv("line_side", "production", 1, "issue", "opp-issue-#{i}") })

    assert_equal [80, 100, 20], [qty("raw_store"), qty("line_side"), qty("production")]
    assert_consistent
  end

  test "pick(fg_store→shipping)과 ship(shipping→customer)이 shipping 을 두고 20회 동시에 와도 교착이 없다" do
    # pick 은 오름차순, ship 은 내림차순으로 shipping 을 지난다.
    assert_operator loc_id("fg_store"), :<, loc_id("shipping")
    assert_operator loc_id("customer"), :<, loc_id("shipping")

    mv("production", "qc", 200, "produce", "opp-seed-prod")
    mv("qc", "fg_store", 200, "qc_pass", "opp-seed-pass")
    mv("fg_store", "shipping", 100, "pick", "opp-seed-pick")

    race(->(i) { mv("fg_store", "shipping", 1, "pick", "opp-pick-#{i}") },
         ->(i) { mv("shipping", "customer", 1, "ship", "opp-ship-#{i}") })

    assert_equal [80, 100, 20], [qty("fg_store"), qty("shipping"), qty("customer")]
    assert_consistent
  end
end
