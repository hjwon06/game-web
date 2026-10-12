# 주문. seq 는 DB 시퀀스가 매기는 접수 순서다(시간 우선 비교는 seq 로 한다).
# reject_reason 은 rejected 일 때만 값이 있다(DB CHECK orders_reject_reason_status_check).
module Securities
  class Order < Record
    self.table_name = "orders"

    SIDES = %w[buy sell].freeze
    ORDER_TYPES = %w[limit market].freeze
    STATUSES = %w[accepted partially_filled filled cancelled rejected].freeze
    REJECT_REASONS = %w[closed tick price_limit insufficient].freeze
    CANCELLABLE = %w[accepted partially_filled].freeze

    belongs_to :account, class_name: "Securities::Account"
    belongs_to :asset, class_name: "Securities::Asset"
    has_one :hold, class_name: "Securities::Hold", dependent: :restrict_with_exception
    has_many :buy_executions, class_name: "Securities::Execution", foreign_key: :buy_order_id,
                              inverse_of: :buy_order, dependent: :restrict_with_exception
    has_many :sell_executions, class_name: "Securities::Execution", foreign_key: :sell_order_id,
                               inverse_of: :sell_order, dependent: :restrict_with_exception
  end
end
