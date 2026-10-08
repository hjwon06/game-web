class SalesOrder < ApplicationRecord
  STATUSES = %w[open partial done].freeze

  has_many :lines, class_name: "SalesOrderLine", dependent: :destroy

  validates :so_no, presence: true, uniqueness: true
  validates :customer, presence: true
  validates :status, inclusion: { in: STATUSES }
end
