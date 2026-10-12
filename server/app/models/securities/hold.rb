# 주문 1건당 묶어 둔 수량. 체결마다 qty 가 줄고 끝나면 released_at 이 찍힌다.
module Securities
  class Hold < Record
    self.table_name = "holds"

    belongs_to :order, class_name: "Securities::Order"
    belongs_to :account, class_name: "Securities::Account"
    belongs_to :asset, class_name: "Securities::Asset"
  end
end
