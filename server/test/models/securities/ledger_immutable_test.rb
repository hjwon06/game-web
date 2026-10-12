require "test_helper"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# ledger_entries 는 append-only 다. 방어선은 DB 트리거(ledger_entries_append_only)이고 모델에는 막는 코드가 없다.
class Securities::LedgerImmutableTest < ActiveSupport::TestCase
  setup do
    asset = Securities::Asset.create!(code: "VT-A", name: "가상종목", kind: "equity", base_price: 1000)
    from = Securities::Account.create!(code: "VT-FROM", name: "가상예탁", kind: "depository")
    to = Securities::Account.create!(code: "VT-TO", name: "가상투자자", kind: "investor")
    settlement = Securities::Settlement.create!(settle_date: Date.new(2026, 10, 30), status: "settled")
    @entry = Securities::LedgerEntry.create!(settlement: settlement, from_account: from, to_account: to,
                                             asset: asset, qty: 4, idem_key: "ledger-1")
  end

  # 트리거 예외가 바깥 트랜잭션(테스트)을 중단시키지 않게 savepoint 안에서 실행한다.
  def blocked(&block)
    assert_raises(ActiveRecord::StatementInvalid) do
      Securities::Record.transaction(requires_new: true, &block)
    end
  end

  test "SQL UPDATE 는 DB 트리거가 막고 행은 그대로다" do
    error = blocked { Securities::LedgerEntry.where(id: @entry.id).update_all(qty: 99) }

    assert_match(/append-only/, error.message)
    assert_match(/UPDATE/, error.message)
    assert_equal 4, Securities::LedgerEntry.find(@entry.id).qty
  end

  test "SQL DELETE 는 DB 트리거가 막고 행은 그대로다" do
    error = blocked { Securities::LedgerEntry.where(id: @entry.id).delete_all }

    assert_match(/append-only/, error.message)
    assert_match(/DELETE/, error.message)
    assert Securities::LedgerEntry.exists?(@entry.id)
  end

  test "TRUNCATE 도 막는다" do
    error = blocked { Securities::Record.lease_connection.execute("TRUNCATE ledger_entries") }

    assert_match(/append-only/, error.message)
    assert Securities::LedgerEntry.exists?(@entry.id)
  end

  test "INSERT 는 된다(막는 건 수정·삭제뿐이다)" do
    second = Securities::LedgerEntry.create!(settlement: @entry.settlement, from_account: @entry.from_account,
                                             to_account: @entry.to_account, asset: @entry.asset,
                                             qty: 1, idem_key: "ledger-2")

    assert_equal 2, Securities::LedgerEntry.where(id: [@entry.id, second.id]).count
  end
end
