require "test_helper"

class PutawayRuleTest < ActiveSupport::TestCase
  setup do
    @steel = Product.create!(sku: "RAW-STEEL", name: "강판 시트", uom: "ea", kind: "raw")
    @rack = Location.find_by!(code: "RAW-A-01")
  end

  def assert_db_rejects(&block)
    assert_raises(ActiveRecord::StatementInvalid) { PutawayRule.transaction(requires_new: true, &block) }
  end

  test "priority 는 1~100 정수여야 한다. 앱 검증과 DB 체크가 둘 다 막는다" do
    [0, 101, 1.5, nil].each do |bad|
      assert_not PutawayRule.new(product: @steel, location: @rack, priority: bad).valid?, "priority=#{bad.inspect}"
    end
    assert PutawayRule.new(product: @steel, location: @rack, priority: 1).valid?
    assert PutawayRule.new(product: @steel, location: @rack, priority: 100).valid?

    rule = PutawayRule.create!(product: @steel, location: @rack, priority: 10)
    assert_db_rejects { rule.update_columns(priority: 101) }
    assert_db_rejects { rule.update_columns(priority: 0) }
  end

  test "같은 (품목, 위치) 규칙은 하나뿐이다. 전 품목(NULL) 규칙도 위치당 하나다" do
    PutawayRule.create!(product: @steel, location: @rack, priority: 10)
    PutawayRule.create!(product: nil, location: @rack, priority: 90)

    assert_not PutawayRule.new(product: @steel, location: @rack, priority: 20).valid?
    assert_not PutawayRule.new(product: nil, location: @rack, priority: 20).valid?
    assert_db_rejects { PutawayRule.new(product: nil, location: @rack, priority: 20).save!(validate: false) }
  end

  test "active 스코프는 꺼 둔 규칙을 뺀다" do
    on = PutawayRule.create!(product: @steel, location: @rack, priority: 10)
    PutawayRule.create!(product: nil, location: Location.find_by!(code: "RAW-A-04"), priority: 90, active: false)

    assert_equal [on.id], PutawayRule.active.pluck(:id)
  end

  test "ensure_defaults! 는 있는 품목·위치의 규칙만 만들고 다시 불러도 늘지 않는다" do
    first = PutawayRule.ensure_defaults!

    # 강판 전용 1 + 공용 RAW-A-04 1 + FG 랙 4. 볼트·패킹은 품목이 아직 없어 건너뛴다.
    assert_equal 6, first
    assert_equal 0, PutawayRule.ensure_defaults!
    rows = PutawayRule.joins(:location).order("locations.code").pluck("locations.code", :product_id, :priority)
    assert_equal [["FG-A-01", nil, 50], ["FG-A-02", nil, 50], ["FG-A-03", nil, 50], ["FG-A-04", nil, 50],
                  ["RAW-A-01", @steel.id, 10], ["RAW-A-04", nil, 90]], rows

    Product.create!(sku: "RAW-BOLT", name: "볼트 M8", uom: "ea", kind: "raw")
    assert_equal 1, PutawayRule.ensure_defaults!, "품목이 생기면 그 규칙만 추가된다"
  end

  test "ensure_defaults! 는 이미 바꿔 둔 priority 를 덮어쓰지 않는다" do
    PutawayRule.create!(product: @steel, location: @rack, priority: 33)

    PutawayRule.ensure_defaults!

    assert_equal 33, PutawayRule.find_by!(product: @steel, location: @rack).priority
  end

  test "기본값은 자재마다 전용 랙 하나, 공용 랙은 priority 90, 완제품은 FG 랙 4개 공용이다" do
    by_sku = PutawayRule::DEFAULTS.select(&:first).to_h { |sku, code, priority| [sku, [code, priority]] }
    assert_equal({ "RAW-STEEL" => ["RAW-A-01", 10], "RAW-BOLT" => ["RAW-A-02", 10], "RAW-PACK" => ["RAW-A-03", 10] }, by_sku)
    shared = PutawayRule::DEFAULTS.reject(&:first)
    assert_equal ["RAW-A-04"], shared.select { |_, _, p| p == 90 }.map { |_, code, _| code }
    assert_equal %w[FG-A-01 FG-A-02 FG-A-03 FG-A-04], shared.select { |_, code, _| code.start_with?("FG-") }.map { |_, code, _| code }
  end
end
