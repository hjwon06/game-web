require "test_helper"

# 이동 유형 9개와 경로 표는 그대로고, 위치 판정만 "조상 중 구역 루트" 기준이라 칸(bin)끼리도 경로가 맞는다.
class Inventory::MoveBinPathsTest < ActiveSupport::TestCase
  setup do
    @product = Product.create!(sku: "RAW-BIN", name: "칸 강판", uom: "ea", kind: "raw")
    @raw_bin = Location.find_by!(code: "RAW-A-03-04")
    @fg_bin = Location.find_by!(code: "FG-A-01-02")
  end

  def mv(from, to, qty, type, key)
    Inventory::Move.call(product: @product, lot: nil, from: from, to: to, qty: qty, move_type: type, ref: nil, idempotency_key: key)
  end

  def on_hand(loc) = Quant.where(product_id: @product.id, location_id: loc.id).sum(:qty)

  test "raw_store 칸 → line_side(feed) → production(issue) 가 경로 규칙을 통과한다" do
    mv("supplier", "receiving", 50, "receive", "bin-recv")
    mv("receiving", @raw_bin, 50, "putaway", "bin-put")
    feed = mv(@raw_bin, "line_side", 30, "feed", "bin-feed")
    issue = mv("line_side", "production", 20, "issue", "bin-issue")

    assert_equal ["feed", @raw_bin.id], [feed.move_type, feed.from_location_id]
    assert_equal ["issue", Location.find_by!(code: "line_side").id], [issue.move_type, issue.from_location_id]
    assert_equal [20, 10], [on_hand(@raw_bin), on_hand(Location.find_by!(code: "line_side"))]
    assert_equal [], Inventory::Reconcile.call
  end

  test "raw 칸에서 production 으로 직접 issue 는 경로 오류다" do
    mv("supplier", "receiving", 50, "receive", "bin-recv-direct")
    mv("receiving", @raw_bin, 50, "putaway", "bin-put-direct")

    assert_raises(Inventory::Move::InvalidPath) { mv(@raw_bin, "production", 1, "issue", "bin-direct-issue") }
    assert_raises(Inventory::Move::InvalidPath) { mv("raw_store", "production", 1, "issue", "bin-direct-issue-2") }
    assert_equal 2, StockMove.count
  end

  test "qc → fg_store 칸(qc_pass) → shipping(pick) → customer(ship) 흐름도 칸 기준으로 통과한다" do
    mv("production", "qc", 40, "produce", "bin-prod")
    mv("qc", @fg_bin, 40, "qc_pass", "bin-pass")
    mv(@fg_bin, "shipping", 15, "pick", "bin-pick")
    mv("shipping", "customer", 15, "ship", "bin-ship")
    assert_equal 25, on_hand(@fg_bin)
    assert_equal [], Inventory::Reconcile.call
  end

  test "ship 은 fg 칸에서 바로 나갈 수 없다" do
    mv("production", "qc", 40, "produce", "bin-prod-2")
    mv("qc", @fg_bin, 40, "qc_pass", "bin-pass-2")

    assert_raises(Inventory::Move::InvalidPath) { mv(@fg_bin, "customer", 1, "ship", "bin-ship-direct") }
  end

  test "칸이 속한 구역과 이동 유형이 안 맞으면 InvalidPath" do
    mv("supplier", "receiving", 10, "receive", "bin-bad-recv")
    # putaway 의 도착지는 raw_store 구역이어야 한다. fg_store 칸은 안 된다.
    assert_raises(Inventory::Move::InvalidPath) { mv("receiving", @fg_bin, 1, "putaway", "bin-bad-1") }
    # issue 의 출발지는 line_side. fg_store 칸에서는 안 된다.
    assert_raises(Inventory::Move::InvalidPath) { mv(@fg_bin, "production", 1, "issue", "bin-bad-2") }
    # feed 의 출발지는 raw_store 구역, pick 의 출발지는 fg_store 구역이다.
    assert_raises(Inventory::Move::InvalidPath) { mv(@fg_bin, "line_side", 1, "feed", "bin-bad-feed") }
    assert_raises(Inventory::Move::InvalidPath) { mv(@raw_bin, "shipping", 1, "pick", "bin-bad-pick") }
    # 칸에서 칸으로 옮기는 유형은 없다.
    assert_raises(Inventory::Move::InvalidPath) { mv(@raw_bin, Location.find_by!(code: "RAW-A-03-05"), 1, "putaway", "bin-bad-3") }
    assert_equal 1, StockMove.count
  end

  test "칸을 virtual 로 바꾸거나 부모를 끊으면 구역 판정이 깨져 InvalidPath" do
    mv("supplier", "receiving", 10, "receive", "bin-kind-recv")

    Location.where(id: @raw_bin.id).update_all(kind: "virtual")
    assert_raises(Inventory::Move::InvalidPath) { mv("receiving", Location.find(@raw_bin.id), 1, "putaway", "bin-kind-1") }

    Location.where(id: @raw_bin.id).update_all(kind: "physical", parent_id: nil)
    assert_raises(Inventory::Move::InvalidPath) { mv("receiving", Location.find(@raw_bin.id), 1, "putaway", "bin-orphan-1") }
    assert_equal 1, StockMove.count
  end

  test "이동 유형은 9개이고 경로 표와 StockMove::MOVE_TYPES 가 같다" do
    assert_equal 9, Inventory::Move::ALLOWED_PATHS.size
    assert_equal Inventory::Move::ALLOWED_PATHS.keys.sort, StockMove::MOVE_TYPES.sort
    assert_equal %w[feed pick], StockMove::MOVE_TYPES.sort - %w[issue produce putaway qc_fail qc_pass receive ship]
  end

  test "line_side 는 용량 800 의 물리 위치이고 구역 루트다" do
    line_side = Location.find_by!(code: "line_side")

    assert_equal ["physical", 800, "line_side"], [line_side.kind, line_side.capacity_units, line_side.zone_code]
    assert_includes Location.ensure_defaults!.map(&:code), "line_side"
  end

  test "line_side 용량(800)을 넘기는 feed 는 CapacityExceeded 다" do
    mv("supplier", "receiving", 900, "receive", "bin-cap-recv")
    Location.where(id: @raw_bin.id).update_all(capacity_units: 1_000)
    mv("receiving", @raw_bin, 900, "putaway", "bin-cap-put")
    mv(@raw_bin, "line_side", 800, "feed", "bin-cap-ok")

    assert_raises(Inventory::CapacityExceeded) { mv(@raw_bin, "line_side", 1, "feed", "bin-cap-over") }
  end
end
