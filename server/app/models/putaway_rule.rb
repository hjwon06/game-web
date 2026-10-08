# 적치 규칙: 어느 품목(NULL = 전 품목)을 어느 구역·랙(하위 칸 전부)에 먼저 쌓는가. priority 가 작을수록 먼저다.
# 고르는 일은 Ops::Putaway 가 한다. 이 모델은 데이터와 기본값(시드)만 가진다.
class PutawayRule < ApplicationRecord
  PRIORITY = (1..100)

  # [품목 sku(nil = 전 품목), 위치 code, priority]. 자재별 전용 랙 1개씩, 공용 랙은 뒤(90), 완제품은 FG 랙 4개 공용.
  # 마이그레이션 20261008140001 이 같은 값을 넣는다. 바꿀 때 둘을 같이 바꾼다.
  DEFAULTS = [
    ["RAW-STEEL", "RAW-A-01", 10], ["RAW-BOLT", "RAW-A-02", 10], ["RAW-PACK", "RAW-A-03", 10], [nil, "RAW-A-04", 90],
    [nil, "FG-A-01", 50], [nil, "FG-A-02", 50], [nil, "FG-A-03", 50], [nil, "FG-A-04", 50]
  ].freeze

  belongs_to :product, optional: true
  belongs_to :location

  validates :priority, numericality: { only_integer: true, in: PRIORITY }
  validates :active, inclusion: { in: [true, false] }
  validates :location_id, uniqueness: { scope: :product_id }

  scope :active, -> { where(active: true) }

  # 재실행 안전. 위치나 품목이 아직 없는 행은 건너뛴다(품목은 inventory:seed 가 만든다). 만든 규칙 수를 돌려준다.
  def self.ensure_defaults!
    products = Product.where(sku: DEFAULTS.filter_map(&:first)).index_by(&:sku)
    locations = Location.where(code: DEFAULTS.map { |_, code, _| code }).index_by(&:code)
    DEFAULTS.count do |sku, code, priority|
      product = sku && products[sku]
      location = locations[code]
      next false if (sku && product.nil?) || location.nil?

      rule = find_or_initialize_by(product: product, location: location)
      created = rule.new_record?
      rule.update!(priority: priority) if created
      created
    end
  end
end
