# 자산: 현금(KRW) 1 + 종목. 이름·코드는 전부 가상이다(코드는 V 로 시작).
module Securities
  class Asset < Record
    self.table_name = "assets"

    KINDS = %w[cash equity].freeze
    CASH_CODE = "VKRW".freeze

    has_many :positions, class_name: "Securities::Position", dependent: :restrict_with_exception
    has_many :orders, class_name: "Securities::Order", dependent: :restrict_with_exception
    has_many :ledger_entries, class_name: "Securities::LedgerEntry", dependent: :restrict_with_exception
  end
end
