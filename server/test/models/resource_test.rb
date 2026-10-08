require "test_helper"

class ResourceTest < ActiveSupport::TestCase
  setup { Resource.ensure_defaults! }

  test "자원 12개가 종류별로 시드된다: 지게차 2, 입고도크 2, 출하도크 2, 작업자 6" do
    assert_equal 12, Resource.count
    assert_equal({ "forklift" => 2, "dock_in" => 2, "dock_out" => 2, "worker" => 6 }, Resource.group(:kind).count)
    assert_equal %w[FORK-01 FORK-02], Resource.where(kind: "forklift").order(:code).pluck(:code)
    assert_equal "DOCK-OUT-02", Resource.where(kind: "dock_out").order(:code).last.code
    assert_equal "WORKER-06", Resource.where(kind: "worker").order(:code).last.code
  end

  test "재실행해도 중복이 없고 기존 행의 id 가 바뀌지 않는다" do
    before = Resource.order(:code).pluck(:id, :code)
    2.times { Resource.ensure_defaults! }
    assert_equal before, Resource.order(:code).pluck(:id, :code)
  end

  test "home 위치: 지게차·입고도크는 입고대, 출하도크는 출하대, 작업자는 없음" do
    homes = Resource.includes(:home_location).group_by(&:kind).transform_values { |rs| rs.map { |r| r.home_location&.code }.uniq }
    assert_equal({ "forklift" => ["receiving"], "dock_in" => ["receiving"], "dock_out" => ["shipping"], "worker" => [nil] }, homes)
  end

  test "code 중복과 잘못된 kind 는 모델과 DB 둘 다 거부한다" do
    assert_not Resource.new(kind: "forklift", code: "FORK-01").valid?
    assert_not Resource.new(kind: "crane", code: "CRANE-01").valid?

    # insert_all 은 중복을 조용히 건너뛰므로 검증만 끈 save 로 DB 제약을 직접 때린다.
    assert_raises(ActiveRecord::RecordNotUnique) do
      Resource.transaction(requires_new: true) { Resource.new(kind: "forklift", code: "FORK-01").save!(validate: false) }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      Resource.transaction(requires_new: true) { Resource.new(kind: "crane", code: "CRANE-01").save!(validate: false) }
    end
  end
end
