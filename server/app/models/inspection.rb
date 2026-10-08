class Inspection < ApplicationRecord
  RESULTS = %w[pass fail].freeze

  belongs_to :lot
  belongs_to :work_order
  belongs_to :stock_move

  validates :result, inclusion: { in: RESULTS }
  validates :defect_qty, numericality: { greater_than_or_equal_to: 0 }
  # 검사 1행 = 이동 1건의 수량(합격 이동이면 합격량, 불량 이동이면 불량량). 미검사량 계산의 근거다(tasks 는 prune 으로 지워진다).
  validates :qty, numericality: { greater_than_or_equal_to: 0 }
end
