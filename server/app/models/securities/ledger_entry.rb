# 원장. append-only 이고 방어선은 DB 트리거다(ledger_entries_append_only). 모델은 관계와 읽기 전용 표시만 둔다.
module Securities
  class LedgerEntry < Record
    self.table_name = "ledger_entries"

    belongs_to :settlement, class_name: "Securities::Settlement"
    belongs_to :from_account, class_name: "Securities::Account", inverse_of: :outgoing_entries
    belongs_to :to_account, class_name: "Securities::Account", inverse_of: :incoming_entries
    belongs_to :asset, class_name: "Securities::Asset"

    # 저장된 행은 읽기 전용이다. update!/destroy 가 SQL 까지 가기 전에 모델에서 막는다(공장 StockMove 와 같은 이중 방어).
    def readonly?
      persisted? || super
    end
  end
end
