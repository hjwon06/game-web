# 체결. settlement_id 는 결제에 묶이기 전까지 NULL 이다.
module Securities
  class Execution < Record
    self.table_name = "executions"

    belongs_to :asset, class_name: "Securities::Asset"
    belongs_to :buy_order, class_name: "Securities::Order", inverse_of: :buy_executions
    belongs_to :sell_order, class_name: "Securities::Order", inverse_of: :sell_executions
    belongs_to :settlement, class_name: "Securities::Settlement", optional: true
  end
end
