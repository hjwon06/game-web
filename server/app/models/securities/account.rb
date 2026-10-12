# 계좌. depository(예탁)는 개시 잔고의 출처라 positions 행을 갖지 않는다(공장의 가상 위치와 같은 역할).
module Securities
  class Account < Record
    self.table_name = "accounts"

    KINDS = %w[investor broker clearing depository].freeze

    has_many :positions, class_name: "Securities::Position", dependent: :restrict_with_exception
    has_many :holds, class_name: "Securities::Hold", dependent: :restrict_with_exception
    has_many :orders, class_name: "Securities::Order", dependent: :restrict_with_exception
    has_many :outgoing_entries, class_name: "Securities::LedgerEntry", foreign_key: :from_account_id,
                                inverse_of: :from_account, dependent: :restrict_with_exception
    has_many :incoming_entries, class_name: "Securities::LedgerEntry", foreign_key: :to_account_id,
                                inverse_of: :to_account, dependent: :restrict_with_exception
  end
end
