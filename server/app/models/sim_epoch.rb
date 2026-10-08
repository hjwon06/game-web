# 시뮬레이션 기준 시각 이력. 이 시각 이전 생산은 재고로 소급하지 않는다. 가장 최근 행이 현재 기준이다.
class SimEpoch < ApplicationRecord
  validates :started_at, presence: true

  def self.latest = order(started_at: :desc, id: :desc).first

  # 밀린 생산을 버리고 지금부터 새로 시작한다.
  def self.rebase!(at: Time.current) = create!(started_at: at)
end
