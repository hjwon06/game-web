# 주문 취소. accepted · partially_filled 만 cancelled 가 되고 홀드가 풀린다(released_at). 끝난 주문은 그대로 돌려준다.
# 같은 계좌 행을 FOR UPDATE 로 잠근 뒤 주문을 다시 읽는다 — PlaceOrder 와 같은 잠금 순서(계좌 행)이고,
# 호출자가 들고 있는 order 객체의 status 는 낡았을 수 있어 신뢰하지 않는다.
module Securities
  class CancelOrder
    def self.call(order:, at:)
      Record.transaction do
        Account.lock.find(order.account_id)
        current = Order.find(order.id)
        next current unless Order::CANCELLABLE.include?(current.status)

        current.update!(status: "cancelled")
        Hold.where(order_id: current.id, released_at: nil).update_all(released_at: at)
        current
      end
    end
  end
end
