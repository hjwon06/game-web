# 작업 자원(지게차·도크·작업자). 수량은 제이 미보정 기본값이다: 지게차 2, 입고도크 2, 출하도크 2, 작업자 6.
class Resource < ApplicationRecord
  KINDS = %w[forklift dock_in dock_out worker].freeze

  # [kind, code 접두, 개수, home 위치 code(없으면 nil)]
  DEFAULTS = [
    ["forklift", "FORK",     2, "receiving"],
    ["dock_in",  "DOCK-IN",  2, "receiving"],
    ["dock_out", "DOCK-OUT", 2, "shipping"],
    ["worker",   "WORKER",   6, nil]
  ].freeze

  # 재실행 안전. 이미 있는 code 는 건드리지 않는다. 위치 시드(Location.ensure_defaults!)가 먼저 있어야 home 이 채워진다.
  def self.ensure_defaults!
    homes = Location.where(code: DEFAULTS.filter_map { |d| d[3] }).pluck(:code, :id).to_h
    rows = DEFAULTS.flat_map do |kind, prefix, count, home|
      (1..count).map { |n| { kind: kind, code: format("%s-%02d", prefix, n), home_location_id: home && homes.fetch(home) } }
    end
    have = where(code: rows.map { |r| r[:code] }).pluck(:code)
    missing = rows.reject { |r| have.include?(r[:code]) }
    insert_all(missing, unique_by: :code) if missing.any?
    where(code: rows.map { |r| r[:code] }).order(:id).to_a
  end

  belongs_to :home_location, class_name: "Location", optional: true
  has_many :tasks, dependent: :restrict_with_error

  validates :code, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }
end
