class Product < ApplicationRecord
  KINDS = %w[raw wip fg].freeze

  has_many :lots, dependent: :restrict_with_error
  has_many :bom_lines, dependent: :restrict_with_error
  has_many :stock_moves, dependent: :restrict_with_error
  has_many :quants, dependent: :restrict_with_error
  has_many :work_orders, dependent: :restrict_with_error, inverse_of: :item
  has_many :sales_order_lines, dependent: :restrict_with_error

  validates :sku, presence: true, uniqueness: true
  validates :name, presence: true
  validates :uom, presence: true
  validates :kind, inclusion: { in: KINDS }

  # work_orders.product 문자열과 같은 정규화(공백 접기 + 소문자)로 품목을 찾고, 없으면 fg 로 만든다.
  def self.resolve_legacy_name(name)
    squished = name.to_s.squish
    return nil if squished.empty?

    where("lower(regexp_replace(btrim(name), '\\s+', ' ', 'g')) = ?", squished.downcase).first ||
      create!(sku: "AUTO-#{SecureRandom.hex(5)}", name: squished, uom: "ea", kind: "fg")
  end
end
