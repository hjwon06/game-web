class WorkOrder < ApplicationRecord
  STATUSES = %w[queued active done].freeze

  belongs_to :machine
  has_many :production_events, dependent: :restrict_with_error

  validates :code, presence: true, uniqueness: true
  validates :product, presence: true
  validates :target_qty, numericality: { only_integer: true, greater_than: 0 }
  validates :produced_qty, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :status, inclusion: { in: STATUSES }
end
