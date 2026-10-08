class BomLine < ApplicationRecord
  belongs_to :product
  belongs_to :component, class_name: "Product"

  validates :qty_per, numericality: { greater_than: 0 }
  validates :component_id, uniqueness: { scope: :product_id }
  validate :component_differs_from_product

  private

  def component_differs_from_product
    errors.add(:component_id, "자기 자신을 구성품으로 둘 수 없다") if product_id.present? && product_id == component_id
  end
end
