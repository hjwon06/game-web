require "test_helper"

# 같은 멱등키가 다른 수량으로 동시에 오면 하나만 이동을 만들고 다른 하나는 IdempotencyConflict 여야 한다.
# 어느 쪽이 이기든 상관없다. 성공 1 + 충돌 1 이고 원장은 1건, 현재고는 이긴 쪽 수량이다.
# Move 의 잠금 후 재확인(next same_as_request!)과 RecordNotUnique 경로의 대조를 지우면 둘 다 성공으로 보여 실패해야 한다.
class ConcurrencyIdempotencyConflictTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  ROUNDS = 10
  JOIN_SECONDS = 15

  WIPE_SQL = "TRUNCATE inspections, stock_moves, quants, lots, bom_lines, sales_order_lines, sales_orders, " \
             "work_orders, products RESTART IDENTITY CASCADE".freeze

  setup do
    wipe
    @product = Product.create!(sku: "RAW-CONFLICT", name: "충돌 자재", uom: "ea", kind: "raw")
  end

  teardown { wipe }

  # 원장은 TRUNCATE 가 트리거로 막혀 있어 트리거 해제·TRUNCATE·재활성화를 한 트랜잭션에 묶는다.
  def wipe
    conn = ActiveRecord::Base.connection
    conn.transaction do
      conn.execute("ALTER TABLE stock_moves DISABLE TRIGGER stock_moves_no_truncate")
      conn.execute(WIPE_SQL)
      conn.execute("ALTER TABLE stock_moves ENABLE TRIGGER stock_moves_no_truncate")
    end
  end

  def receive(qty, key)
    Inventory::Move.call(product: @product, lot: nil, from: "supplier", to: "receiving", qty: qty, move_type: "receive",
                         ref: nil, idempotency_key: key)
  end

  test "같은 키 + 다른 수량 동시 2건은 하나는 성공, 하나는 IdempotencyConflict" do
    ROUNDS.times do |round|
      key = "conflict-#{round}"
      start = Queue.new
      threads = [3, 7].map do |qty|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            start.pop
            receive(qty, key)
          rescue StandardError => e
            e
          end
        end
      end
      threads.each { |t| t.report_on_exception = false }
      2.times { start << true }
      outcomes = threads.map { |t| t.join(JOIN_SECONDS) ? t.value : flunk("#{JOIN_SECONDS}초 안에 끝나지 않았다") }

      winners = outcomes.grep(StockMove)
      losers = outcomes.grep(Exception)
      assert_equal 1, winners.size, "라운드 #{round}: 성공은 정확히 1건 — #{outcomes.map(&:class)}"
      assert_equal [Inventory::IdempotencyConflict], losers.map(&:class), "라운드 #{round}: #{losers.map(&:message)}"
      assert_equal 1, StockMove.where(idempotency_key: key).count
    end

    receiving = Location.find_by!(code: "receiving")
    expected = StockMove.where(move_type: "receive").sum(:qty)
    assert_equal expected, Quant.where(product_id: @product.id, location_id: receiving.id).sum(:qty)
    assert_equal [], Inventory::Reconcile.call
  end
end
