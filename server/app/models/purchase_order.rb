# 발주(PO). confirmed(주문 확정, 트럭이 오는 중) -> arrived(도착, 하차 중) -> done(전 라인 입고 완료). cancelled 는 하차가 끝까지 못 간 경우다.
# 상태는 Simulation::Inbound(confirmed -> arrived)와 Ops::Tick(arrived -> done / cancelled)만 바꾼다.
class PurchaseOrder < ApplicationRecord
  STATUSES = %w[confirmed arrived done cancelled].freeze
  OPEN = %w[confirmed arrived].freeze
  UNLOAD_OPEN = %w[planned started].freeze

  belongs_to :supplier
  has_many :lines, class_name: "PurchaseOrderLine", dependent: :restrict_with_error

  validates :po_no, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :ordered_at, :expected_at, presence: true

  scope :open_orders, -> { where(status: OPEN) }

  # 다음 발주 번호 PO-YYYYMMDD-NNNN (날짜 = at 의 UTC 날짜, 번호는 그날 마지막 번호 + 1).
  # 호출부(Inbound)가 InboundState 행을 잠근 트랜잭션 안이라 번호가 겹치지 않는다. 겹쳐도 po_no 유니크가 막는다.
  def self.next_po_no(at)
    prefix = "PO-#{at.utc.strftime('%Y%m%d')}-"
    last = where("po_no LIKE ?", "#{sanitize_sql_like(prefix)}%").maximum(:po_no)
    format("%s%04d", prefix, last ? last.split("-").last.to_i + 1 : 1)
  end

  # 전 라인을 다 받았으면 done. 아직이면 그대로 둔다.
  def complete_if_received!
    return unless status == "arrived"

    update!(status: "done") if lines.reload.all? { |l| l.qty_received >= l.qty_ordered }
  end

  # 하차 작업 하나가 취소됐다. 그 발주에 남은 열린 하차가 없고 아직 다 못 받았으면 발주를 닫는다(cancelled).
  # 안 닫으면 도착한 채로 영영 열려 있어 "들어오는 중" 수량과 이중 발주 방지가 그 자재를 막는다.
  def self.unload_cancelled!(task)
    return unless task.kind == "unload" && task.ref_type == "PurchaseOrderLine"

    po = PurchaseOrderLine.find_by(id: task.ref_id)&.purchase_order
    return unless po&.status == "arrived"
    return if Task.where(kind: "unload", ref_type: "PurchaseOrderLine", ref_id: po.lines.select(:id), status: UNLOAD_OPEN).exists?

    po.update!(status: "cancelled")
  end
end
