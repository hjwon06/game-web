require "test_helper"

# 꺼낼 재고 고르기: FIFO(로트 생성 순) 이면서 가용(quants.qty - active 예약 합) >= 필요량인 (칸, 로트).
class Ops::RemovalTest < ActiveSupport::TestCase
  T0 = Time.utc(2026, 10, 8, 12, 0, 0)

  setup do
    Resource.ensure_defaults!
    Ops::Plan.reseed!(21)
    @steel = Product.create!(sku: "RAW-STEEL", name: "강판 시트", uom: "ea", kind: "raw")
    @fg = Product.create!(sku: "FG-BRACKET-A", name: "브래킷 A", uom: "ea", kind: "fg")
    @seq = 0
  end

  def lot_at(product, no, at) = Lot.create!(product: product, lot_no: no, created_at: at, updated_at: at)

  def stock(product, code, qty, lot: nil)
    Inventory::Move.call(product: product, lot: lot, from: "supplier", to: "receiving", qty: qty, move_type: "receive",
                         ref: nil, idempotency_key: "rm-r-#{@seq += 1}")
    Inventory::Move.call(product: product, lot: lot, from: "receiving", to: code, qty: qty, move_type: "putaway",
                         ref: nil, idempotency_key: "rm-p-#{@seq += 1}")
  end

  # 그 칸·품목·로트에서 qty 만큼을 예약한 작업(feed)을 계획한다.
  def hold(product, code, qty, lot: nil)
    Ops::Plan.call(kind: "feed", product: product, lot: lot, qty: qty, from: code, to: "line_side", ref: nil, earliest_at: T0)
  end

  def choose(qty, product: @steel, scope: "raw_store", **opts) = Ops::Removal.choose(product: product, qty: qty, from_scope: scope, **opts)

  test "FIFO: 로트가 오래된 칸이 먼저고, 로트가 같으면 칸 코드 순이다" do
    old = lot_at(@steel, "R-OLD", T0 - 7200)
    new = lot_at(@steel, "R-NEW", T0 - 3600)
    stock(@steel, "RAW-A-01-01", 300, lot: new)
    stock(@steel, "RAW-A-01-02", 300, lot: old)

    source = choose(100)

    assert_equal ["RAW-A-01-02", old.id, 300], [source.location.code, source.lot.id, source.available]

    same = lot_at(@steel, "R-SAME", T0 - 7200)
    stock(@steel, "RAW-A-01-03", 300, lot: same) # 로트 시각이 old 와 같다
    assert_equal "RAW-A-01-02", choose(100).location.code, "시각이 같으면 코드가 앞선 칸"
  end

  test "로트 없는 재고가 가장 오래된 것으로 친다. require_lot 이면 후보가 아니다" do
    lot = lot_at(@steel, "R-1", T0 - 7200)
    stock(@steel, "RAW-A-01-01", 300, lot: lot)
    stock(@steel, "RAW-A-01-02", 300)

    assert_nil choose(100).lot
    assert_equal lot.id, choose(100, require_lot: true).lot.id
  end

  test "예약된 재고는 다른 작업이 못 잡는다: 가용 = 현재고 - active 예약 합" do
    lot = lot_at(@steel, "R-1", T0 - 3600)
    stock(@steel, "RAW-A-01-01", 700, lot: lot)
    hold(@steel, "RAW-A-01-01", 500, lot: lot)

    assert_nil choose(300), "가용 200 < 필요 300"
    assert_equal 200, choose(200).available
    assert_equal 200, choose(300, partial: true).available, "partial 이면 있는 만큼(호출자가 min 으로 자른다)"

    hold(@steel, "RAW-A-01-01", 200, lot: lot)
    assert_nil choose(1, partial: true), "전부 잡혔으면 partial 이어도 nil"
  end

  test "예약은 (칸, 품목, 로트) 별이다: 같은 칸의 다른 로트·다른 품목 예약은 가용을 깎지 않는다" do
    a = lot_at(@steel, "R-A", T0 - 7200)
    b = lot_at(@steel, "R-B", T0 - 3600)
    other = Product.create!(sku: "RAW-OTHER", name: "다른 자재", uom: "ea", kind: "raw")
    stock(@steel, "RAW-A-01-01", 500, lot: a)
    stock(@steel, "RAW-A-01-01", 500, lot: b)
    stock(other, "RAW-A-01-01", 500)
    hold(@steel, "RAW-A-01-01", 500, lot: a)
    hold(other, "RAW-A-01-01", 500)

    source = choose(500)

    assert_equal [b.id, 500], [source.lot.id, source.available], "a 로트는 전량 예약돼 b 로트가 나온다"
    assert_nil choose(1, product: other), "다른 품목은 자기 예약만 본다(전량 예약됨)"
  end

  test "FIFO 칸의 가용이 모자라면 가용이 충분한 다음 칸을 먼저 고르고, 없을 때만 partial 이 오래된 칸의 남은 만큼을 준다" do
    old = lot_at(@steel, "R-OLD", T0 - 7200)
    new = lot_at(@steel, "R-NEW", T0 - 3600)
    stock(@steel, "RAW-A-01-01", 500, lot: old)
    stock(@steel, "RAW-A-01-02", 500, lot: new)
    hold(@steel, "RAW-A-01-01", 300, lot: old) # old 가용 200

    assert_equal new.id, choose(400).lot.id, "old 는 200 뿐이라 400 이 가용인 new"
    assert_equal new.id, choose(400, partial: true).lot.id, "충분한 칸이 있으면 partial 이어도 그쪽"

    hold(@steel, "RAW-A-01-02", 400, lot: new) # new 가용 100
    assert_nil choose(400)
    picked = choose(400, partial: true)
    assert_equal [old.id, 200], [picked.lot.id, picked.available], "충분한 칸이 없으면 FIFO 첫 가용 칸"
  end

  test "범위: from_scope 아래 칸만 본다. 위치 code·Location·배열을 받고 창고 자체의 재고도 포함한다" do
    lot = lot_at(@steel, "R-1", T0 - 3600)
    stock(@steel, "RAW-A-02-01", 300, lot: lot)
    Inventory::Move.call(product: @steel, lot: lot, from: "supplier", to: "receiving", qty: 100, move_type: "receive",
                         ref: nil, idempotency_key: "rm-wh")

    assert_equal "RAW-A-02-01", choose(100, scope: "RAW-A-02").location.code
    assert_equal "RAW-A-02-01", choose(100, scope: Location.find_by!(code: "raw_store")).location.code
    assert_nil choose(100, scope: "RAW-A-01"), "다른 랙"
    assert_nil choose(100, scope: "fg_store"), "다른 창고"
    assert_equal "RAW-A-02-01", choose(100, scope: %w[RAW-A-01 RAW-A-02]).location.code
    assert_equal "receiving", choose(100, scope: "receiving").location.code, "스코프 자신도 포함"
  end

  test "재고가 0 이하이거나 다른 품목뿐이면 nil 이다" do
    lot = lot_at(@fg, "F-1", T0)
    Inventory::Move.call(product: @fg, lot: lot, from: "production", to: "qc", qty: 300, move_type: "produce", ref: nil,
                         idempotency_key: "rm-fg-1")
    Inventory::Move.call(product: @fg, lot: lot, from: "qc", to: "FG-A-01-01", qty: 300, move_type: "qc_pass", ref: nil,
                         idempotency_key: "rm-fg-2")

    assert_nil choose(100), "강판은 없다"
    assert_equal "FG-A-01-01", choose(100, product: @fg, scope: "fg_store").location.code

    Inventory::Move.call(product: @fg, lot: lot, from: "FG-A-01-01", to: "shipping", qty: 300, move_type: "pick",
                         ref: nil, idempotency_key: "rm-empty")
    assert_nil choose(1, product: @fg, scope: "fg_store"), "qty 0 인 quant 는 후보가 아니다"
  end

  test "취소된 작업의 예약(released)은 가용을 깎지 않는다" do
    lot = lot_at(@steel, "R-1", T0)
    stock(@steel, "RAW-A-01-01", 500, lot: lot)
    held = hold(@steel, "RAW-A-01-01", 500, lot: lot)
    assert_nil choose(100)

    held.update!(status: "cancelled", cancel_reason: "test")

    assert_equal 500, choose(500).available
  end

  test "choose 는 재고도 예약도 바꾸지 않는다" do
    lot = lot_at(@steel, "R-1", T0)
    stock(@steel, "RAW-A-01-01", 500, lot: lot)

    assert_no_difference -> { Reservation.count } do
      assert_no_difference -> { StockMove.count } do
        choose(100)
      end
    end
  end
end
