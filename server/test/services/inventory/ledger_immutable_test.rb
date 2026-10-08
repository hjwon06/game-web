require "test_helper"

# stock_moves 는 append-only 다. 방어선은 DB 트리거이고, 앱 레벨(readonly?)은 2차 방어다.
class Inventory::LedgerImmutableTest < ActiveSupport::TestCase
  setup do
    product = Product.create!(sku: "RAW-LEDGER", name: "원장 자재", uom: "ea", kind: "raw")
    @move = Inventory::Move.call(product: product, lot: nil, from: "supplier", to: "receiving", qty: 4,
                                 move_type: "receive", ref: nil, idempotency_key: "ledger-1")
  end

  # 트리거 예외가 바깥 트랜잭션을 중단시키지 않게 savepoint 안에서 실행한다.
  def blocked(&block)
    assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.transaction(requires_new: true, &block)
    end
  end

  test "SQL UPDATE 는 DB 트리거가 막고 행은 그대로다" do
    error = blocked { StockMove.where(id: @move.id).update_all(qty: 99) }

    assert_match(/append-only/, error.message)
    assert_match(/UPDATE/, error.message)
    assert_equal 4, StockMove.find(@move.id).qty
  end

  test "SQL DELETE 는 DB 트리거가 막고 행은 그대로다" do
    error = blocked { StockMove.where(id: @move.id).delete_all }

    assert_match(/append-only/, error.message)
    assert_match(/DELETE/, error.message)
    assert StockMove.exists?(@move.id)
  end

  test "모델 update!/destroy 는 저장된 뒤엔 ReadOnlyRecord 다" do
    assert_raises(ActiveRecord::ReadOnlyRecord) { @move.update!(qty: 5) }
    assert_raises(ActiveRecord::ReadOnlyRecord) { @move.destroy }
    assert_equal 4, StockMove.find(@move.id).qty
  end

  test "원장이 안 바뀌었으니 Reconcile 도 일치한다" do
    blocked { StockMove.where(id: @move.id).update_all(qty: 99) }
    assert_equal [], Inventory::Reconcile.call
  end
end
