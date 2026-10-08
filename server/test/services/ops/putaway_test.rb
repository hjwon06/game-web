require "test_helper"

# 적치 칸 고르기: 규칙 priority 순 -> 규칙마다 ① 같은 품목 + 남은 용량 >= qty ② 빈 칸. 없으면 nil.
class Ops::PutawayTest < ActiveSupport::TestCase
  P = Simulation::Config::PALLET_QTY

  setup do
    Resource.ensure_defaults!
    @steel = Product.create!(sku: "RAW-STEEL", name: "강판 시트", uom: "ea", kind: "raw")
    @bolt = Product.create!(sku: "RAW-BOLT", name: "볼트 M8", uom: "ea", kind: "raw")
    @pack = Product.create!(sku: "RAW-PACK", name: "고무 패킹", uom: "ea", kind: "raw")
    @fg = Product.create!(sku: "FG-BRACKET-A", name: "브래킷 A", uom: "ea", kind: "fg")
    @seq = 0
  end

  def choose(product, qty = P) = Ops::Putaway.choose(product: product, qty: qty)

  def code_of(product, qty = P) = choose(product, qty)&.code

  def rack_bins(rack) = Location.where("code LIKE ?", "#{rack}-%").order(:code).pluck(:code)

  # 칸에 재고를 만든다(Ops 를 거치지 않는다).
  def stock(product, code, qty)
    Inventory::Move.call(product: product, lot: nil, from: "supplier", to: "receiving", qty: qty, move_type: "receive",
                         ref: nil, idempotency_key: "pw-r-#{@seq += 1}")
    Inventory::Move.call(product: product, lot: nil, from: "receiving", to: code, qty: qty, move_type: "putaway",
                         ref: nil, idempotency_key: "pw-p-#{@seq += 1}")
  end

  def fill_rack(product, rack)
    rack_bins(rack).each { |code| stock(product, code, Location::BIN_CAPACITY) }
  end

  test "기본 규칙: 자재마다 전용 랙, 완제품은 FG 랙" do
    PutawayRule.ensure_defaults!

    assert_equal %w[RAW-A-01-01 RAW-A-02-01 RAW-A-03-01 FG-A-01-01],
                 [code_of(@steel), code_of(@bolt), code_of(@pack), code_of(@fg)]
  end

  test "priority 가 작은 규칙이 먼저다. 코드 순서나 만든 순서가 아니다" do
    PutawayRule.create!(product: nil, location: Location.find_by!(code: "RAW-A-01"), priority: 50)
    PutawayRule.create!(product: nil, location: Location.find_by!(code: "RAW-A-03"), priority: 5)
    PutawayRule.create!(product: nil, location: Location.find_by!(code: "RAW-A-02"), priority: 20)

    assert_equal "RAW-A-03-01", code_of(@steel)

    PutawayRule.find_by!(priority: 5).update!(priority: 60)
    assert_equal "RAW-A-02-01", code_of(@steel)
  end

  test "priority 가 같으면 품목 전용 규칙이 전 품목 규칙보다 먼저, 그다음 위치 코드 순이다" do
    PutawayRule.create!(product: nil, location: Location.find_by!(code: "RAW-A-01"), priority: 30)
    PutawayRule.create!(product: @steel, location: Location.find_by!(code: "RAW-A-03"), priority: 30)
    PutawayRule.create!(product: @steel, location: Location.find_by!(code: "RAW-A-02"), priority: 30)

    assert_equal "RAW-A-02-01", code_of(@steel), "전용 두 개 중 코드가 앞선 랙"
    assert_equal "RAW-A-01-01", code_of(@bolt), "전용 규칙이 없는 품목은 전 품목 규칙만 본다"
  end

  test "전용 랙이 꽉 차면 공용 랙으로 넘어가고, 전용 랙에 자리가 나면 다시 전용 랙이다" do
    PutawayRule.ensure_defaults!
    fill_rack(@steel, "RAW-A-01")

    assert_equal "RAW-A-04-01", code_of(@steel)

    Inventory::Move.call(product: @steel, lot: nil, from: "RAW-A-01-03", to: "line_side", qty: P,
                         move_type: "feed", ref: nil, idempotency_key: "pw-free")
    assert_equal "RAW-A-01-03", code_of(@steel), "03 에 같은 품목 + 남은 용량이 팔레트 1개"
  end

  test "다른 자재는 남의 전용 랙을 쓰지 못한다: 자기 전용 랙과 공용 랙이 다 차면 nil" do
    PutawayRule.ensure_defaults!
    fill_rack(@steel, "RAW-A-04")

    assert_equal "RAW-A-02-01", code_of(@bolt), "공용 랙이 차도 볼트 전용 랙이 있다"

    fill_rack(@bolt, "RAW-A-02")
    assert_nil choose(@bolt), "강판 랙 RAW-A-01 의 빈 칸은 볼트 몫이 아니다"
    assert_equal "RAW-A-01-01", code_of(@steel), "강판은 자기 랙이 비어 있어 갈 곳이 있다"
  end

  test "같은 품목이 있고 남은 용량이 충분한 칸이 빈 칸보다 먼저다. 용량이 모자라면 빈 칸" do
    PutawayRule.create!(product: nil, location: Location.find_by!(code: "raw_store"), priority: 50)
    stock(@steel, "RAW-A-01-02", Location::BIN_CAPACITY - (P / 2)) # 남은 용량 팔레트의 절반
    stock(@steel, "RAW-A-01-03", Location::BIN_CAPACITY - (2 * P)) # 남은 용량 팔레트 2개

    assert_equal "RAW-A-01-03", code_of(@steel), "01 은 빈 칸이지만 같은 품목 칸(03)이 먼저"
    assert_equal "RAW-A-01-02", code_of(@steel, P / 4), "작은 수량이면 02 도 들어간다(코드 순 첫 칸)"
    assert_equal "RAW-A-01-01", code_of(@bolt), "다른 품목은 품목이 든 칸(02, 03)을 건너뛴 빈 칸"
  end

  test "이미 계획된 적치도 칸 용량과 품목으로 센다" do
    PutawayRule.create!(product: nil, location: Location.find_by!(code: "RAW-A-01"), priority: 50)
    lot = Lot.create!(product: @steel, lot_no: "LOT-PW")
    Ops::Plan.call(kind: "putaway", product: @steel, lot: lot, qty: Location::BIN_CAPACITY, from: "receiving", to: "RAW-A-01-01",
                   ref: nil, earliest_at: Time.current)

    assert_equal "RAW-A-01-02", code_of(@steel), "01 은 계획된 적치로 이미 찼다"
    assert_equal "RAW-A-01-02", code_of(@bolt)
  end

  test "품목 종류가 받는 창고 밖의 칸은 규칙이 가리켜도 쓰지 않는다: 전 품목 FG 규칙에 자재가 딸려 가지 않는다" do
    PutawayRule.create!(product: nil, location: Location.find_by!(code: "FG-A-01"), priority: 1)
    PutawayRule.create!(product: nil, location: Location.find_by!(code: "RAW-A-04"), priority: 90)

    assert_equal "RAW-A-04-01", code_of(@steel), "priority 1 이 FG 랙이어도 자재는 raw_store 안에서만"
    assert_equal "FG-A-01-01", code_of(@fg)
  end

  test "칸 용량이 수량보다 작으면 빈 칸이어도 고르지 않는다" do
    PutawayRule.create!(product: nil, location: Location.find_by!(code: "RAW-A-01"), priority: 50)

    assert_nil choose(@steel, Location::BIN_CAPACITY + 1)
  end

  test "꺼 둔 규칙과 규칙 없음은 nil 이다" do
    assert_nil choose(@steel)

    rule = PutawayRule.create!(product: @steel, location: Location.find_by!(code: "RAW-A-01"), priority: 10)
    assert_equal "RAW-A-01-01", code_of(@steel)

    rule.update!(active: false)
    assert_nil choose(@steel)
  end

  test "bins 는 규칙 순서로 중복 없이 이 품목이 쓸 수 있는 칸을 돌려준다" do
    PutawayRule.create!(product: @steel, location: Location.find_by!(code: "RAW-A-01"), priority: 10)
    PutawayRule.create!(product: nil, location: Location.find_by!(code: "raw_store"), priority: 90) # RAW-A-01 칸도 포함하지만 한 번만
    stock(@bolt, "RAW-A-01-02", P)

    bins = Ops::Putaway.bins(product: @steel)

    assert_equal 24, bins.size
    assert_equal bins.map(&:code).uniq, bins.map(&:code)
    assert_equal rack_bins("RAW-A-01"), bins.first(6).map(&:code), "전용 랙이 앞"
    assert_equal [P, Set[@bolt.id]], bins.find { |b| b.code == "RAW-A-01-02" }.then { |b| [b.used, b.products] }
  end
end
