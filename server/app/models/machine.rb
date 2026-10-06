class Machine < ApplicationRecord
  STATES = %w[running stopped broken].freeze

  has_many :commands, dependent: :restrict_with_error
  has_many :state_events, class_name: "MachineStateEvent", dependent: :restrict_with_error
  has_many :work_orders, dependent: :restrict_with_error
  has_many :production_events, dependent: :restrict_with_error

  validates :code, presence: true, uniqueness: true
  validates :name, presence: true
  validates :state, inclusion: { in: STATES }
  validates :version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
