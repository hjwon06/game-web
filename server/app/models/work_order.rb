class WorkOrder < ApplicationRecord
  STATUSES = %w[queued active done].freeze

  belongs_to :machine
  # 문자열 컬럼 product(bin/sim 이 아직 씀)와 이름이 겹치므로 연관은 item 으로 둔다. FK 는 product_id, NOT NULL.
  belongs_to :item, class_name: "Product", foreign_key: :product_id, inverse_of: :work_orders
  belongs_to :sales_order_line, optional: true
  has_many :production_events, dependent: :restrict_with_error
  has_many :inspections, dependent: :restrict_with_error

  # 문자열 product 만 넘기는 기존 호출부(bin/sim, 시드, 기존 테스트)의 product_id 를 채운다.
  before_validation :resolve_item_from_name, if: -> { product_id.nil? }

  validates :code, presence: true, uniqueness: true
  validates :product, presence: true
  validates :target_qty, numericality: { only_integer: true, greater_than: 0 }
  validates :produced_qty, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :status, inclusion: { in: STATUSES }

  private

  def resolve_item_from_name
    self.item = Product.resolve_legacy_name(product)
  end
end
