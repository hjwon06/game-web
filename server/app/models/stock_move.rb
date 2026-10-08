# 이동 원장. append-only. 진짜 방어선은 DB 트리거이고, readonly? 는 앱 레벨 2차 방어다.
class StockMove < ApplicationRecord
  # 9개 동결. 추가 금지. feed·pick 은 ③b 에서 늘었다(DB CHECK 는 마이그레이션 20261008050000).
  MOVE_TYPES = %w[receive putaway feed issue produce qc_pass qc_fail pick ship].freeze

  belongs_to :product
  belongs_to :lot, optional: true
  belongs_to :from_location, class_name: "Location"
  belongs_to :to_location, class_name: "Location"

  validates :qty, numericality: { greater_than: 0 }
  validates :move_type, inclusion: { in: MOVE_TYPES }
  validates :idempotency_key, presence: true, uniqueness: true
  validate :locations_differ

  # 새 레코드는 저장 가능, 한번 저장된 뒤에는 수정/삭제 불가
  def readonly?
    !new_record? || super
  end

  private

  def locations_differ
    errors.add(:to_location_id, "출발지와 도착지가 같을 수 없다") if from_location_id.present? && from_location_id == to_location_id
  end
end
