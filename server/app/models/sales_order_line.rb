class SalesOrderLine < ApplicationRecord
  belongs_to :sales_order
  belongs_to :product
  has_many :work_orders, dependent: :restrict_with_error

  validates :ordered_qty, numericality: { greater_than: 0 }
end
