class ProductionEvent < ApplicationRecord
  belongs_to :machine
  belongs_to :work_order

  validates :bucket_start, :bucket_end, presence: true
  validates :good_qty, :defect_qty, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :machine_version, numericality: { only_integer: true }
end
