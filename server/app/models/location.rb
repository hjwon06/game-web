class Location < ApplicationRecord
  KINDS = %w[physical virtual].freeze

  has_many :quants, dependent: :restrict_with_error

  validates :code, presence: true, uniqueness: true
  validates :name, presence: true
  validates :kind, inclusion: { in: KINDS }

  def physical? = kind == "physical"
  def virtual? = kind == "virtual"
end
