require "test_helper"

class LocationHierarchyTest < ActiveSupport::TestCase
  test "칸 48개·랙 8개·구역 2개가 시드되고 기본 위치 11개(line_side, inventory_loss 포함)는 그대로다" do
    assert_equal 48, Location.where(level: "bin").count
    assert_equal 8, Location.where(level: "rack").count
    assert_equal 2, Location.where(level: "zone").count
    assert_equal 69, Location.count # 11 + 2 + 8 + 48
    assert Location.exists?(code: "line_side"), "line_side 가 시드돼야 한다"
    assert_equal ["virtual", nil], Location.where(code: "inventory_loss").pick(:kind, :capacity_units)
    assert_equal 24, Location.where(level: "bin", parent: Location.where(level: "rack", parent: Location.find_by!(code: "RAW-A"))).count
    assert_equal 24, Location.where(level: "bin", parent: Location.where(level: "rack", parent: Location.find_by!(code: "FG-A"))).count

    Location::DEFAULTS.each do |code, _name, kind, role|
      loc = Location.find_by!(code: code)
      capacity = code == "line_side" ? Location::LINE_SIDE_CAPACITY : nil
      assert_equal [kind, role, nil, capacity], [loc.kind, loc.role, loc.parent_id, loc.capacity_units], code
    end
    assert_equal 4000, Location.find_by!(code: "line_side").capacity_units # 팔레트(500) 8개
  end

  test "재실행해도 중복이 생기지 않는다" do
    before = Location.order(:code).pluck(:id, :code)
    2.times { Location.ensure_defaults! }
    assert_equal before, Location.order(:code).pluck(:id, :code)
  end

  test "칸 코드는 RAW-A-01-03 꼴이고 부모 사슬은 칸 > 랙 > 구역 > 창고, 용량은 2000이다(팔레트 500 x 4)" do
    bin = Location.find_by!(code: "RAW-A-01-03")
    assert_equal ["bin", "physical", 2000], [bin.level, bin.kind, bin.capacity_units]
    assert_equal "RAW-A-01", bin.parent.code
    assert_equal "rack", bin.parent.level
    assert_equal "RAW-A", bin.parent.parent.code
    assert_equal "raw_store", bin.parent.parent.parent.code
    assert_equal "fg_store", Location.find_by!(code: "FG-A-04-06").parent.parent.parent.code
    assert_equal 2000, Location.where(level: "bin").distinct.pluck(:capacity_units).sole
  end

  test "zone_code 는 칸이든 창고든 소속 구역 code 를 돌려주고 가상 위치는 자기 code 다" do
    assert_equal "raw_store", Location.find_by!(code: "RAW-A-01-03").zone_code
    assert_equal "raw_store", Location.find_by!(code: "RAW-A-02").zone_code
    assert_equal "fg_store", Location.find_by!(code: "FG-A-04-06").zone_code
    assert_equal "raw_store", Location.find_by!(code: "raw_store").zone_code
    assert_equal "receiving", Location.find_by!(code: "receiving").zone_code
    assert_equal "supplier", Location.find_by!(code: "supplier").zone_code
  end

  test "부모 없는 칸은 zone_code 가 자기 code 라 어느 구역에도 속하지 않는다" do
    Location.where(code: "RAW-A-01-03").update_all(parent_id: nil)
    assert_equal "RAW-A-01-03", Location.find_by!(code: "RAW-A-01-03").zone_code
  end

  test "순환 부모가 있어도 zone_code 조회가 끝난다" do
    a = Location.find_by!(code: "RAW-A-01")
    b = Location.find_by!(code: "RAW-A-02")
    Location.where(id: a.id).update_all(parent_id: b.id)
    Location.where(id: b.id).update_all(parent_id: a.id)
    assert_equal "RAW-A-01-01", Location.find_by!(code: "RAW-A-01-01").zone_code
  end

  test "레벨과 부모가 안 맞으면 검증이 거부한다" do
    rack = Location.find_by!(code: "RAW-A-01")
    bad = Location.new(code: "X-1", name: "x", kind: "physical", level: "bin", parent: Location.find_by!(code: "raw_store"))
    assert_not bad.valid?
    assert bad.errors[:parent_id].any?

    assert Location.new(code: "X-2", name: "x", kind: "physical", level: "bin", parent: rack, capacity_units: 10).valid?
    assert_not Location.new(code: "X-3", name: "x", kind: "physical", level: "warehouse", parent: rack).valid?
    assert_not Location.new(code: "X-4", name: "x", kind: "physical", level: "bin", parent: rack, capacity_units: 0).valid?
  end

  test "DB 제약: 잘못된 level, 0 이하 용량, 자기 자신을 부모로 두는 것은 거부된다" do
    bin = Location.find_by!(code: "RAW-A-01-01")
    assert_check_violation { Location.where(id: bin.id).update_all(level: "pallet") }
    assert_check_violation { Location.where(id: bin.id).update_all(capacity_units: 0) }
    assert_check_violation { Location.where(id: bin.id).update_all(parent_id: bin.id) }
  end

  test "자식이 있는 위치는 지울 수 없다" do
    assert_not Location.find_by!(code: "RAW-A-01").destroy
  end

  private

  def assert_check_violation(&block)
    assert_raises(ActiveRecord::StatementInvalid) { Location.transaction(requires_new: true, &block) }
  end
end
