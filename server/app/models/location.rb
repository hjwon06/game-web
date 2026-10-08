class Location < ApplicationRecord
  KINDS = %w[physical virtual].freeze

  # 위치 9개는 스키마가 아니라 데이터다. 마이그레이션 20261008000002 의 INSERT 와 같은 값.
  # [code, name, kind, role]
  DEFAULTS = [
    ["supplier",   "공급처",     "virtual",  "supplier"],
    ["customer",   "고객",       "virtual",  "customer"],
    ["production", "생산",       "virtual",  "production"],
    ["scrap",      "폐기",       "virtual",  "scrap"],
    ["receiving",  "입고대",     "physical", "receiving"],
    ["raw_store",  "자재창고",   "physical", "storage"],
    ["qc",         "검사대",     "physical", "qc"],
    ["fg_store",   "완제품창고", "physical", "storage"],
    ["shipping",   "출하대",     "physical", "shipping"]
  ].freeze

  # 재실행 안전. 이미 있는 code 는 건드리지 않는다.
  def self.ensure_defaults!
    DEFAULTS.map do |code, name, kind, role|
      find_or_create_by!(code: code) do |l|
        l.name = name
        l.kind = kind
        l.role = role
      end
    end
  end

  has_many :quants, dependent: :restrict_with_error

  validates :code, presence: true, uniqueness: true
  validates :name, presence: true
  validates :kind, inclusion: { in: KINDS }

  def physical? = kind == "physical"
  def virtual? = kind == "virtual"
end
