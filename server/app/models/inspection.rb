class Inspection < ApplicationRecord
  RESULTS = %w[pass fail].freeze

  belongs_to :lot
  belongs_to :work_order
  belongs_to :stock_move

  validates :result, inclusion: { in: RESULTS }
  validates :defect_qty, numericality: { greater_than_or_equal_to: 0 }
end
