class Command < ApplicationRecord
  KINDS = %w[start stop break repair].freeze

  belongs_to :machine
  has_many :state_events, class_name: "MachineStateEvent", dependent: :restrict_with_error

  validates :idempotency_key, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }
  validates :base_version, numericality: { only_integer: true }
end
