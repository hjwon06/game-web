require "test_helper"

class Inventory::MoveCapacityTest < ActiveSupport::TestCase
  setup do
    @product = Product.create!(sku: "RAW-CAP", name: "용량 강판", uom: "ea", kind: "raw")
    @other = Product.create!(sku: "RAW-CAP2", name: "용량 볼트", uom: "ea", kind: "raw")
    # 아래 테스트는 용량 400 칸을 가정한다(수량이 그에 맞춰져 있다). 시드 용량(팔레트 4개 = 2000)과 별개로 이 테스트 안에서만 400 으로 둔다.
    Location.where(code: %w[RAW-A-01-01 RAW-A-01-02]).update_all(capacity_units: 400)
    @bin = Location.find_by!(code: "RAW-A-01-01")
    @bin2 = Location.find_by!(code: "RAW-A-01-02")
    mv("supplier", "receiving", 1000, "receive", "cap-recv")
    mv("supplier", "receiving", 1000, "receive", "cap-recv-other", product: @other)
  end

  def mv(from, to, qty, type, key, product: @product)
    Inventory::Move.call(product: product, lot: nil, from: from, to: to, qty: qty, move_type: type, ref: nil,
                         idempotency_key: key)
  end

  def bin_total(loc) = Quant.where(location_id: loc.id).sum(:qty)

  test "용량 400 칸에 400까지는 들어가고 1 넘기면 CapacityExceeded 이며 원장도 재고도 안 바뀐다" do
    mv("receiving", @bin, 300, "putaway", "cap-1")
    mv("receiving", @bin, 100, "putaway", "cap-2") # 정확히 400 = 허용
    assert_equal 400, bin_total(@bin)

    moves_before = StockMove.count
    receiving_before = Quant.where(location_id: Location.find_by!(code: "receiving").id, product_id: @product.id).sum(:qty)

    error = assert_raises(Inventory::CapacityExceeded) { mv("receiving", @bin, 1, "putaway", "cap-3") }
    assert_includes error.message, "RAW-A-01-01"
    assert_equal moves_before, StockMove.count
    assert_equal 0, StockMove.where(idempotency_key: "cap-3").count
    assert_equal 400, bin_total(@bin)
    assert_equal receiving_before, Quant.where(location_id: Location.find_by!(code: "receiving").id, product_id: @product.id).sum(:qty)
  end

  test "가득 찬 칸이 있어도 다른 칸으로는 성공한다" do
    mv("receiving", @bin, 400, "putaway", "cap-full")
    assert_raises(Inventory::CapacityExceeded) { mv("receiving", @bin, 101, "putaway", "cap-over") }

    mv("receiving", @bin2, 101, "putaway", "cap-other-bin")
    assert_equal 101, bin_total(@bin2)
    assert_equal 400, bin_total(@bin)
  end

  test "용량은 품목을 가리지 않고 칸 안의 합계로 센다" do
    mv("receiving", @bin, 300, "putaway", "cap-p1")
    assert_raises(Inventory::CapacityExceeded) { mv("receiving", @bin, 101, "putaway", "cap-p2", product: @other) }
    mv("receiving", @bin, 100, "putaway", "cap-p3", product: @other)
    assert_equal 400, bin_total(@bin)
  end

  test "칸에서 빼내면 자리가 난다" do
    mv("receiving", @bin, 400, "putaway", "cap-out-1")
    mv(@bin, "line_side", 150, "feed", "cap-out-2") # 칸에서 나가는 길은 feed(→ line_side)다
    mv("receiving", @bin, 150, "putaway", "cap-out-3")
    assert_equal 400, bin_total(@bin)
  end

  test "이미 처리된 멱등키 재요청은 칸이 가득 차도 용량 검사 없이 원래 이동을 돌려준다" do
    first = mv("receiving", @bin, 400, "putaway", "cap-replay")
    again = mv("receiving", @bin, 400, "putaway", "cap-replay")
    assert_equal first.id, again.id
    assert_equal 400, bin_total(@bin)
  end

  test "용량이 없는 위치(창고 루트)에는 제한이 없다" do
    mv("receiving", "raw_store", 1000, "putaway", "cap-root")
    assert_equal 1000, bin_total(Location.find_by!(code: "raw_store"))
  end

  test "용량은 도착지에만 건다: 용량 초과 상태의 칸에서도 출고는 된다" do
    mv("receiving", @bin, 400, "putaway", "cap-over-state")
    Location.where(id: @bin.id).update_all(capacity_units: 100)
    mv(@bin, "line_side", 10, "feed", "cap-feed-over")
    assert_equal 390, bin_total(@bin)
    assert_equal 10, Quant.where(location_id: Location.find_by!(code: "line_side").id).sum(:qty)
  end

  test "용량을 줄이면 다음 입고부터 새 값으로 막는다 (잠금 뒤에 다시 읽는다)" do
    Location.where(id: @bin.id).update_all(capacity_units: 50)
    # @bin 객체의 capacity_units 는 옛 값(400)이다.
    assert_equal 400, @bin.capacity_units
    assert_raises(Inventory::CapacityExceeded) { mv("receiving", @bin, 51, "putaway", "cap-shrunk") }
  end
end

# 같은 칸으로 서로 다른 품목이 동시에 들어오면 quants 행이 달라 행 잠금만으로는 합계를 못 지킨다.
# 칸 행을 FOR NO KEY UPDATE 로 잠그지 않으면 둘 다 통과해 600 이 된다.
class Inventory::MoveCapacityConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  JOIN_SECONDS = 15
  WIPE_SQL = "TRUNCATE inspections, stock_moves, quants, lots, bom_lines, sales_order_lines, sales_orders, " \
             "work_orders, products RESTART IDENTITY CASCADE".freeze

  setup do
    wipe
    @a = Product.create!(sku: "RAW-CC-A", name: "동시 A", uom: "ea", kind: "raw")
    @b = Product.create!(sku: "RAW-CC-B", name: "동시 B", uom: "ea", kind: "raw")
  end

  teardown { wipe }

  # 원장은 append-only 라 커밋된 데이터는 TRUNCATE 트리거를 잠깐 끄고 한 트랜잭션 안에서만 지운다.
  def wipe
    conn = ActiveRecord::Base.connection
    conn.transaction do
      conn.execute("ALTER TABLE stock_moves DISABLE TRIGGER stock_moves_no_truncate")
      conn.execute(WIPE_SQL)
      conn.execute("ALTER TABLE stock_moves ENABLE TRIGGER stock_moves_no_truncate")
    end
  end

  def mv(product, to, qty, type, key, from: "receiving")
    Inventory::Move.call(product: product, lot: nil, from: from, to: to, qty: qty, move_type: type, ref: nil, idempotency_key: key)
  end

  test "서로 다른 품목 칸 용량의 3/4 + 3/4 가 칸으로 동시에 오면 정확히 하나만 성공한다" do
    rounds = Location::BINS_PER_RACK # 라운드마다 비어 있는 새 칸을 쓴다(랙 02 의 6칸)
    qty = Location::BIN_CAPACITY * 3 / 4 # 용량 2000 이면 1500 + 1500 = 3000 이 용량을 넘는다
    rounds.times do |i|
      bin = Location.find_by!(code: format("RAW-A-02-%02d", i + 1))
      mv(@a, "receiving", qty, "receive", "cc-recv-a-#{i}", from: "supplier")
      mv(@b, "receiving", qty, "receive", "cc-recv-b-#{i}", from: "supplier")

      go = Queue.new
      results = Queue.new
      threads = [[@a, "a"], [@b, "b"]].map do |product, tag|
        Thread.new do
          Thread.current.report_on_exception = false
          ActiveRecord::Base.connection_pool.with_connection do
            go.pop
            results << begin
              mv(product, bin, qty, "putaway", "cc-put-#{tag}-#{i}")
            rescue StandardError => e
              e
            end
          end
        end
      end
      2.times { go << true }
      outcomes = Array.new(2) { results.pop(timeout: JOIN_SECONDS) || flunk("#{JOIN_SECONDS}초 안에 안 끝났다") }
      threads.each { |t| t.join(JOIN_SECONDS) }

      assert_equal 1, outcomes.grep(StockMove).size, "라운드 #{i}: #{outcomes.inspect}"
      assert_equal 1, outcomes.grep(Inventory::CapacityExceeded).size, "라운드 #{i}: #{outcomes.inspect}"
      assert_equal qty, Quant.where(location_id: bin.id).sum(:qty)
    end
    assert_equal [], Inventory::Reconcile.call
  end
end
