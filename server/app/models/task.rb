# 작업 한 건 = 시작~완료 시각을 가진 일 단위. 재고는 완료 순간 stock_move 1건(stock_move_id)으로만 움직인다.
# seq 는 DB 트리거(tasks_assign_seq)가 INSERT/UPDATE 마다 새로 배정한다. 앱은 쓰지 않고, 저장 직후 값은 reload 해야 보인다.
# 화면 증분 스트림은 `where("seq > ?", last)` 로 읽되, nextval 순서 != 커밋 순서라서 last 에서 여유 구간을 두고 다시 읽는다.
class Task < ApplicationRecord
  KINDS = %w[unload putaway pick feed inspect load].freeze
  STATUSES = %w[planned started done cancelled].freeze
  RETENTION = 7.days

  belongs_to :resource, optional: true
  belongs_to :product
  belongs_to :lot, optional: true
  belongs_to :from_location, class_name: "Location"
  belongs_to :to_location, class_name: "Location"
  belongs_to :stock_move, optional: true

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
end
