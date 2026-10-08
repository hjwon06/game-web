# 발주 라인. 하차 작업(unload)이 이 라인을 ref 로 가리키고, 하차가 끝날 때마다 qty_received 가 오른다(Ops::Tick).
class PurchaseOrderLine < ApplicationRecord
  belongs_to :purchase_order
  belongs_to :product

  validates :qty_ordered, numericality: { greater_than: 0 }
  validates :qty_received, numericality: { greater_than_or_equal_to: 0 }

  # 하차 1건(qty)이 끝났다. 라인을 잠그고 입고량을 올린 뒤 발주가 다 들어왔으면 done 으로 닫는다. 호출부 트랜잭션 안에서 부른다.
  # 주문량을 넘는 수량은 올리지 않는다(DB CHECK 가 막기 전에 자른다).
  def receive!(qty)
    lock!
    update!(qty_received: [qty_received + qty, qty_ordered].min)
    purchase_order.complete_if_received!
  end

  def remaining = qty_ordered - qty_received
end
