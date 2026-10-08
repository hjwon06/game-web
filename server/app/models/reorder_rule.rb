# 재주문점. coverage(보유 / 분당 수요, 분)가 min_minutes 이상이면 발주하지 않고, 발주하면 max_minutes 분어치까지 채운다.
class ReorderRule < ApplicationRecord
  # [자재 sku, min 분, max 분]. 시드 데이터라 자재가 아직 없으면 건너뛴다.
  DEFAULTS = [
    ["RAW-STEEL", 15, 30],
    ["RAW-BOLT", 15, 30],
    ["RAW-PACK", 15, 30]
  ].freeze

  belongs_to :product

  scope :active, -> { where(active: true) }

  validates :min_minutes, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :max_minutes, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :product_id, uniqueness: true
  validate :max_not_below_min

  # 재실행 안전. 이미 있는 규칙(바꿔 둔 값 포함)은 건드리지 않는다.
  def self.ensure_defaults!
    skus = Product.where(sku: DEFAULTS.map(&:first)).pluck(:sku, :id).to_h
    DEFAULTS.filter_map do |sku, min, max|
      next unless skus[sku]

      find_or_create_by!(product_id: skus[sku]) { |r| r.assign_attributes(min_minutes: min, max_minutes: max) }
    end
  end

  # { 품목 id => 규칙 } (active 만)
  def self.by_product(product_ids) = active.where(product_id: product_ids).index_by(&:product_id)

  private

  def max_not_below_min
    errors.add(:max_minutes, "은 min_minutes 이상이어야 한다") if min_minutes && max_minutes && max_minutes < min_minutes
  end
end
