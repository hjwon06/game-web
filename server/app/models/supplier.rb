# 공급사. lead_time_seconds = 발주에서 트럭이 도착하기까지 걸리는 시간.
class Supplier < ApplicationRecord
  # [code, 이름, 리드타임(초), 대는 자재 sku]. 시드 데이터라 자재가 아직 없으면 그 sku 는 건너뛴다.
  DEFAULTS = [
    ["SUP-STEEL", "한양철강", 120, %w[RAW-STEEL]],
    ["SUP-PARTS", "대한부품", 180, %w[RAW-BOLT RAW-PACK]]
  ].freeze

  has_many :supplier_products, dependent: :restrict_with_error
  has_many :products, through: :supplier_products
  has_many :purchase_orders, dependent: :restrict_with_error

  validates :code, presence: true, uniqueness: true
  validates :name, presence: true
  validates :lead_time_seconds, numericality: { only_integer: true, greater_than: 0 }

  # 재실행 안전. 이미 있는 공급사·연결은 건드리지 않는다(바꿔 둔 리드타임 포함). 자재 품목이 있어야 연결되므로 재고 시드 뒤에 부른다.
  def self.ensure_defaults!
    skus = Product.where(sku: DEFAULTS.flat_map(&:last)).pluck(:sku, :id).to_h
    DEFAULTS.map do |code, name, lead, product_skus|
      supplier = find_or_create_by!(code: code) { |s| s.assign_attributes(name: name, lead_time_seconds: lead) }
      product_skus.filter_map { |sku| skus[sku] }.each do |product_id|
        SupplierProduct.find_or_create_by!(supplier_id: supplier.id, product_id: product_id)
      end
      supplier
    end
  end

  # { 품목 id => 공급사 }. 한 품목에 공급사가 여럿이면 id 가 작은 공급사다. 공급사가 없는 품목은 키가 없다. 쿼리 1회.
  def self.by_product(product_ids)
    pairs = SupplierProduct.where(product_id: product_ids).order(:supplier_id).pluck(:product_id, :supplier_id)
    suppliers = where(id: pairs.map(&:last)).index_by(&:id)
    pairs.each_with_object({}) { |(product_id, supplier_id), out| out[product_id] ||= suppliers.fetch(supplier_id) }
  end
end
