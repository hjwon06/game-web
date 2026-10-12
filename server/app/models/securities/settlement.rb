# 결제일 1건 = 1행. 원장 항목과 체결이 여기에 묶인다.
module Securities
  class Settlement < Record
    self.table_name = "settlements"

    STATUSES = %w[pending settled].freeze

    has_many :executions, class_name: "Securities::Execution", dependent: :restrict_with_exception
    has_many :ledger_entries, class_name: "Securities::LedgerEntry", dependent: :restrict_with_exception
  end
end
