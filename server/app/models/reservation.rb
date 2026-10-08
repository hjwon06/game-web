# 예약: 작업이 가져가기로 한 재고(품목·로트·위치 = quant 기준). 작업 1건에 1행.
# 가용 재고 = quants.qty - active 예약 합. 상태 전이는 작업 상태 변경과 같은 트랜잭션에서 한다(Ops::Plan / Ops::Tick).
class Reservation < ApplicationRecord
  STATUSES = %w[active consumed released].freeze

  belongs_to :task
  belongs_to :product
  belongs_to :lot, optional: true
  belongs_to :location

  validates :status, inclusion: { in: STATUSES }
  validates :qty, numericality: { greater_than: 0 }

  scope :active, -> { where(status: "active") }

  # { [위치 id, 품목 id, 로트 id] => active 예약 합 }. location_ids 가 있으면 그 위치만. 쿼리 1회.
  def self.held(location_ids = nil)
    scope = active
    scope = scope.where(location_id: location_ids) if location_ids
    scope.group(:location_id, :product_id, :lot_id).sum(:qty)
  end
end
