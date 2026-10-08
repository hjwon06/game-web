# 현재고 캐시. 물리 위치 마이너스는 DB 트리거(quants_physical_non_negative)가 막는다.
class Quant < ApplicationRecord
  belongs_to :product
  belongs_to :lot, optional: true
  belongs_to :location

  validates :qty, numericality: true
  validate :physical_location_not_negative

  private

  def physical_location_not_negative
    errors.add(:qty, "물리 위치 재고는 마이너스가 될 수 없다") if qty.present? && qty.negative? && location&.physical?
  end
end
