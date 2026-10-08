# 입고 트럭 스케줄 1행(DB 가 singleton 유니크로 보장). Simulation::Inbound 가 잠그고 읽고 쓴다.
class InboundState < ApplicationRecord
  validates :next_truck_at, presence: true

  # 없으면 만든다(동시 생성이 겹쳐도 ON CONFLICT 로 1행). 행 잠금을 잡고 돌려준다 — 호출부는 트랜잭션 안이어야 한다.
  def self.lock_row!(default_next_truck_at:)
    insert_all([{ singleton: true, next_truck_at: default_next_truck_at }], unique_by: :singleton)
    lock.find_by!(singleton: true)
  end
end
