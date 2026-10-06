class MachineStateEvent < ApplicationRecord
  belongs_to :machine
  belongs_to :command, optional: true

  validates :from_state, :to_state, inclusion: { in: Machine::STATES }
  validates :version, numericality: { only_integer: true, greater_than: 0 }
  validates :at, presence: true
end
