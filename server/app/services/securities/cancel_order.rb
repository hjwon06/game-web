# 주문 취소. accepted · partially_filled 만 cancelled 가 되고 홀드가 풀린다(released_at). 끝난 주문은 그대로 돌려준다.
# 잠금 순서는 PlaceOrder · Match 와 같다: 계좌 행 FOR UPDATE → 책 잠금 → 주문 행 FOR UPDATE.
# 주문을 잠근 뒤 다시 읽어 판정한다 — 체결과 겹치면 체결이 커밋된 뒤의 상태(filled)를 본다.
# 호출자가 들고 있는 order 객체의 status 는 낡았을 수 있어 신뢰하지 않는다.
module Securities
  class CancelOrder
    def self.call(order:, at:)
      Record.transaction do
        Account.lock.find(order.account_id)
        Match.lock_book(order.asset_id)
        current = Order.lock.find(order.id)
        next current unless Order::CANCELLABLE.include?(current.status)

        current.update!(status: "cancelled")
        Hold.where(order_id: current.id, released_at: nil).update_all(released_at: at)
        current
      end
    end
  end
end
