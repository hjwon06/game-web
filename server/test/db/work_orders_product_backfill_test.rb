require "test_helper"

# T10 백필: 매칭 실패 0, 정규화 규칙(공백·대소문자), 문자열 컬럼 유지.
class WorkOrdersProductBackfillTest < ActiveSupport::TestCase
  NORM = "lower(regexp_replace(btrim(%s), '\\s+', ' ', 'g'))".freeze

  setup { @machine = Machine.create!(code: "BF1", name: "백필기") }

  test "매칭 실패 쿼리: product_id 가 없거나 이름이 다른 작업지시는 0건" do
    WorkOrder.create!(code: "BF-1", machine: @machine, product: "브래킷", target_qty: 10)
    WorkOrder.create!(code: "BF-2", machine: @machine, product: "  브래킷  ", target_qty: 10)

    unmatched = WorkOrder.connection.select_value(<<~SQL).to_i
      SELECT count(*) FROM work_orders w
      LEFT JOIN products p ON p.id = w.product_id
      WHERE p.id IS NULL OR #{NORM % 'p.name'} <> #{NORM % 'w.product'}
    SQL
    assert_equal 0, unmatched
  end

  test "공백·대소문자만 다른 문자열은 같은 품목으로 모인다" do
    a = WorkOrder.create!(code: "BF-3", machine: @machine, product: "Bracket  A", target_qty: 5)
    b = WorkOrder.create!(code: "BF-4", machine: @machine, product: " bracket a ", target_qty: 5)
    assert_equal a.product_id, b.product_id
    assert_equal 1, Product.where("lower(name) = 'bracket a'").count
  end

  test "product_id 는 NOT NULL 이고 문자열 product 컬럼은 남아 있다" do
    column = WorkOrder.columns_hash
    assert_equal false, column.fetch("product_id").null
    assert column.key?("product")
    assert column.key?("sales_order_line_id")
  end

  test "stock_moves UPDATE/DELETE 는 DB 트리거가 막는다" do
    p = Product.create!(sku: "T-1", name: "시험품", uom: "ea", kind: "raw")
    from = Location.find_by!(code: "supplier")
    to = Location.find_by!(code: "receiving")
    move = StockMove.create!(product: p, from_location: from, to_location: to, qty: 1,
                             move_type: "receive", idempotency_key: "bf-test-1")
    assert_raises(ActiveRecord::ReadOnlyRecord) { move.update!(qty: 2) }
    error = assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.transaction(requires_new: true) { StockMove.where(id: move.id).update_all(qty: 2) }
    end
    assert_match(/append-only/, error.message)
  end
end
