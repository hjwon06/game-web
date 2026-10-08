class Lot < ApplicationRecord
  belongs_to :product
  has_many :stock_moves, dependent: :restrict_with_error
  has_many :quants, dependent: :restrict_with_error
  has_many :inspections, dependent: :restrict_with_error

  validates :lot_no, presence: true, uniqueness: true
end
