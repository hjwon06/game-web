# 결제분 잔고. 원장 합계의 파생값이다(예탁 계좌는 행이 없다).
module Securities
  class Position < Record
    self.table_name = "positions"

    belongs_to :account, class_name: "Securities::Account"
    belongs_to :asset, class_name: "Securities::Asset"
  end
end
