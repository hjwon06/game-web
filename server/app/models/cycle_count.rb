# 순환 실사 기록: 한 칸·한 품목의 시스템 수량과 센 수량. 차이가 있으면 Ops::CycleCount 가 adjust 이동으로 맞춘다.
class CycleCount < ApplicationRecord
  belongs_to :location
  belongs_to :product
  belongs_to :task, optional: true

  validates :system_qty, :counted_qty, numericality: { greater_than_or_equal_to: 0 }
  validates :counted_at, presence: true

  def difference = counted_qty - system_qty
end
