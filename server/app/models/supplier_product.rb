# 공급사가 대는 품목. (공급사, 품목) 쌍은 유니크다.
class SupplierProduct < ApplicationRecord
  belongs_to :supplier
  belongs_to :product

  validates :product_id, uniqueness: { scope: :supplier_id }
end
