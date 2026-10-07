class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy

  normalizes :name, with: ->(name) { name.strip }

  validates :name, presence: true, uniqueness: true
end
