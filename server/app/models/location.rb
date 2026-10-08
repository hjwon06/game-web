class Location < ApplicationRecord
  KINDS = %w[physical virtual].freeze
  LEVELS = %w[warehouse zone rack bin].freeze
  PARENT_LEVEL = { "zone" => "warehouse", "rack" => "zone", "bin" => "rack" }.freeze

  # 이동 경로를 가르는 물리 구역 5개. 칸·랙·구역은 조상 중 이 코드를 가진 위치의 구역으로 본다.
  ZONE_ROOTS = %w[receiving raw_store line_side qc fg_store shipping].freeze
  MAX_DEPTH = 8 # 순환 데이터가 들어와도 재귀 조회가 멈추게 하는 상한
  LINE_SIDE_CAPACITY = Simulation::Config::LINE_SIDE_CAPACITY # 라인 공급대 하나의 용량(품목 무관 qty 합). 칸(BIN_CAPACITY)이 아니라 루트에 직접 걸린다

  # 위치 10개는 스키마가 아니라 데이터다. line_side 는 ③b 에서 늘었다(마이그레이션 20261008050000 도 같은 값을 넣는다).
  # [code, name, kind, role]
  DEFAULTS = [
    ["supplier",   "공급처",     "virtual",  "supplier"],
    ["customer",   "고객",       "virtual",  "customer"],
    ["production", "생산",       "virtual",  "production"],
    ["scrap",      "폐기",       "virtual",  "scrap"],
    ["receiving",  "입고대",     "physical", "receiving"],
    ["raw_store",  "자재창고",   "physical", "storage"],
    ["line_side",  "라인 공급대", "physical", "line_side"],
    ["qc",       "검사대",     "physical", "qc"],
    ["fg_store",   "완제품창고", "physical", "storage"],
    ["shipping",   "출하대",     "physical", "shipping"]
  ].freeze

  BIN_CAPACITY = Simulation::Config::BIN_CAPACITY # 팔레트 4개
  RACKS_PER_ZONE = 4
  BINS_PER_RACK = 6
  # [창고 code, 구역 code, 이름 접두]. 구역 1개 -> 랙 4개 -> 칸 6개 = 창고당 24칸.
  STORE_LAYOUT = [
    ["raw_store", "RAW-A", "자재"],
    ["fg_store",  "FG-A",  "완제품"]
  ].freeze

  # 재실행 안전. 이미 있는 code 는 건드리지 않는다. 쿼리는 레벨마다 2회(조회 + insert_all)라 테스트 setup 에서 매번 불러도 싸다.
  # 반환값은 기본 위치 10개.
  def self.ensure_defaults!
    roots = DEFAULTS.map do |code, name, kind, role|
      { code: code, name: name, kind: kind, role: role, level: (ZONE_ROOTS.include?(code) ? "warehouse" : nil),
        capacity_units: (code == "line_side" ? LINE_SIDE_CAPACITY : nil) }
    end
    seed_tree(insert_missing(roots))
    where(code: DEFAULTS.map(&:first)).order(:id).to_a
  end

  def self.seed_tree(root_ids)
    zones = STORE_LAYOUT.map do |root, zone, prefix|
      { code: zone, name: "#{prefix} #{zone.split('-').last}구역", level: "zone", parent_id: root_ids.fetch(root) }
    end
    zone_ids = insert_missing(zones.map { |z| tree_row(z) })

    racks = STORE_LAYOUT.flat_map do |_root, zone, prefix|
      (1..RACKS_PER_ZONE).map do |r|
        { code: format("%s-%02d", zone, r), name: "#{prefix} #{zone.split('-').last}-#{format('%02d', r)} 랙",
          level: "rack", parent_id: zone_ids.fetch(zone) }
      end
    end
    rack_ids = insert_missing(racks.map { |r| tree_row(r) })

    bins = STORE_LAYOUT.flat_map do |_root, zone, prefix|
      (1..RACKS_PER_ZONE).flat_map do |r|
        rack = format("%s-%02d", zone, r)
        (1..BINS_PER_RACK).map do |b|
          code = format("%s-%02d", rack, b)
          { code: code, name: "#{prefix} #{code} 칸", level: "bin", parent_id: rack_ids.fetch(rack), capacity_units: BIN_CAPACITY }
        end
      end
    end
    insert_missing(bins.map { |b| tree_row(b) })
  end

  def self.tree_row(attrs) = { kind: "physical", role: "storage", capacity_units: nil, **attrs }

  # 없는 code 만 한 번에 넣고 { code => id } 를 돌려준다. 동시 실행이 겹쳐도 ON CONFLICT DO NOTHING 이라 중복이 없다.
  def self.insert_missing(rows)
    codes = rows.map { |r| r[:code] }
    have = where(code: codes).pluck(:code)
    missing = rows.reject { |r| have.include?(r[:code]) }
    if missing.any?
      keys = missing.flat_map(&:keys).uniq
      insert_all(missing.map { |r| keys.to_h { |k| [k, r[k]] } }, unique_by: :code)
    end
    where(code: codes).pluck(:code, :id).to_h
  end
  private_class_method :seed_tree, :tree_row, :insert_missing

  has_many :quants, dependent: :restrict_with_error
  belongs_to :parent, class_name: "Location", optional: true
  has_many :children, class_name: "Location", foreign_key: :parent_id, inverse_of: :parent, dependent: :restrict_with_error

  validates :code, presence: true, uniqueness: true
  validates :name, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :level, inclusion: { in: LEVELS }, allow_nil: true
  validates :capacity_units, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :parent_matches_level

  def physical? = kind == "physical"
  def virtual? = kind == "virtual"

  # 자기 자신과 조상 중 가장 가까운 ZONE_ROOTS 코드. 없으면 자기 코드(가상 위치 등).
  # 칸(bin)이 몇 단계 아래든 이동 경로 판정은 이 값으로 한다. 쿼리 1회.
  def zone_code
    return code if parent_id.nil?

    sql = self.class.sanitize_sql_array([<<~SQL.squish, id, MAX_DEPTH, ZONE_ROOTS])
      WITH RECURSIVE chain(id, parent_id, code, depth) AS (
        SELECT id, parent_id, code, 0 FROM locations WHERE id = ?
        UNION ALL
        SELECT l.id, l.parent_id, l.code, c.depth + 1 FROM locations l JOIN chain c ON l.id = c.parent_id WHERE c.depth < ?
      )
      SELECT code FROM chain WHERE code IN (?) ORDER BY depth LIMIT 1
    SQL
    self.class.connection.select_value(sql) || code
  end

  private

  def parent_matches_level
    return if level.nil?

    expected = PARENT_LEVEL[level]
    if expected.nil?
      errors.add(:parent_id, "warehouse 는 부모가 없어야 한다") if parent_id.present?
    elsif parent.nil? || parent.level != expected
      errors.add(:parent_id, "#{level} 의 부모는 #{expected} 여야 한다")
    end
  end
end
