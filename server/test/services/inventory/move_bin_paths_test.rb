require "test_helper"

# 이동 유형 7개와 경로 표는 그대로고, 위치 판정만 "조상 중 구역 루트" 기준이라 칸(bin)끼리도 경로가 맞는다.
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

  test "raw_store 칸에서 production 으로 issue 가 기존 경로 규칙을 통과한다" do
    mv("supplier", "receiving", 50, "receive", "bin-recv")
    mv("receiving", @raw_bin, 50, "putaway", "bin-put")
    move = mv(@raw_bin, "production", 20, "issue", "bin-issue")

    assert_equal ["issue", @raw_bin.id], [move.move_type, move.from_location_id]
    assert_equal 30, on_hand(@raw_bin)
    assert_equal [], Inventory::Reconcile.call
  end

  test "qc → fg_store 칸(qc_pass) → customer(ship) 흐름도 칸 기준으로 통과한다" do
    mv("production", "qc", 40, "produce", "bin-prod")
    mv("qc", @fg_bin, 40, "qc_pass", "bin-pass")
    mv(@fg_bin, "customer", 15, "ship", "bin-ship")
    assert_equal 25, on_hand(@fg_bin)
    assert_equal [], Inventory::Reconcile.call
  end

  test "칸이 속한 구역과 이동 유형이 안 맞으면 InvalidPath" do
    mv("supplier", "receiving", 10, "receive", "bin-bad-recv")
    # putaway 의 도착지는 raw_store 구역이어야 한다. fg_store 칸은 안 된다.
    assert_raises(Inventory::Move::InvalidPath) { mv("receiving", @fg_bin, 1, "putaway", "bin-bad-1") }
    # issue 의 출발지는 raw_store 구역. fg_store 칸에서는 안 된다.
    assert_raises(Inventory::Move::InvalidPath) { mv(@fg_bin, "production", 1, "issue", "bin-bad-2") }
    # 칸에서 칸으로 옮기는 8번째 유형은 없다.
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

  test "이동 유형은 여전히 7개다" do
    assert_equal 7, Inventory::Move::ALLOWED_PATHS.size
    assert_equal Inventory::Move::ALLOWED_PATHS.keys.sort, StockMove::MOVE_TYPES.sort
  end
end
