# 작업 한 건 = 시작~완료 시각을 가진 일 단위. 재고는 완료 순간 stock_move 1건(stock_move_id)으로만 움직인다.
# seq 는 DB 트리거(tasks_assign_seq)가 INSERT/UPDATE 마다 새로 배정한다. 앱은 쓰지 않고, 저장 직후 값은 reload 해야 보인다.
# 화면 증분 스트림은 `where("seq > ?", last)` 로 읽되, nextval 순서 != 커밋 순서라서 last 에서 여유 구간을 두고 다시 읽는다.
class Task < ApplicationRecord
  KINDS = %w[unload putaway pick feed inspect load count].freeze
  STATUSES = %w[planned started done cancelled].freeze
  RETENTION = 7.days

  belongs_to :resource, optional: true
  belongs_to :product
  belongs_to :lot, optional: true
  belongs_to :from_location, class_name: "Location"
  belongs_to :to_location, class_name: "Location"
  belongs_to :stock_move, optional: true
  # from 이 물리 위치인 작업만 갖는다(Ops::Plan 이 만든다). prune 은 DB 의 on_delete cascade 가 따라 지운다.
  has_one :reservation, dependent: nil

  # 예약은 작업 상태를 따라 닫힌다: done -> consumed, cancelled -> released. 상태를 저장하는 같은 트랜잭션 안이라
  # Ops::Tick 이든 다른 경로든 작업만 끝나고 예약이 active 로 남아 재고를 영영 잡고 있는 일이 없다.
  after_update :close_reservation, if: :saved_change_to_status?

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :qty, numericality: { greater_than: 0 }
  validates :planned_at, presence: true

  # 끝난 지 retention 이 지난 done/cancelled 만 지운다. stock_moves(원장)는 건드리지 않는다.
  # cancelled 는 finished_at 이 없을 수 있어 updated_at 으로 대신한다. 천 건씩 끊어 지워 긴 잠금을 피한다.
  def self.prune!(before: RETENTION.ago)
    scope = where(status: %w[done cancelled]).where("COALESCE(finished_at, updated_at) < ?", before)
    deleted = 0
    scope.in_batches(of: 1000) { |batch| deleted += batch.delete_all }
    deleted
  end

  RESERVATION_CLOSE = { "done" => "consumed", "cancelled" => "released" }.freeze

  private

  def close_reservation
    closed = RESERVATION_CLOSE[status] or return
    Reservation.where(task_id: id, status: "active").update_all(status: closed, updated_at: Time.current)
  end
end
