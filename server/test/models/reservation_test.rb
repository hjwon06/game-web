require "test_helper"

class ReservationTest < ActiveSupport::TestCase
  setup do
    Resource.ensure_defaults!
    @product = Product.create!(sku: "RAW-RSV", name: "예약 강판", uom: "ea", kind: "raw")
    @bin = Location.find_by!(code: "RAW-A-01-01")
    @t0 = Time.current.change(usec: 0)
  end

  def make_task(qty: 10)
    Task.create!(kind: "feed", resource: Resource.find_by!(code: "FORK-01"), product: @product, qty: qty, planned_at: @t0,
                 expected_finish_at: @t0 + 30.seconds, from_location: @bin, to_location: Location.find_by!(code: "line_side"))
  end

  def assert_db_rejects(&block)
    assert_raises(ActiveRecord::StatementInvalid) { Reservation.transaction(requires_new: true, &block) }
  end

  test "qty 는 0 보다 커야 하고 status 는 active/consumed/released 뿐이다(앱 검증 + DB 체크)" do
    task = make_task
    assert_not Reservation.new(task: task, product: @product, location: @bin, qty: 0).valid?
    assert_not Reservation.new(task: task, product: @product, location: @bin, qty: 5, status: "gone").valid?

    r = Reservation.create!(task: task, product: @product, location: @bin, qty: 5)
    assert_equal "active", r.status, "기본은 active"
    assert_db_rejects { r.update_columns(qty: 0) }
    assert_db_rejects { r.update_columns(status: "gone") }
  end

  test "작업 1건에 예약은 하나뿐이다" do
    task = make_task
    Reservation.create!(task: task, product: @product, location: @bin, qty: 5)

    assert_db_rejects { Reservation.new(task: task, product: @product, location: @bin, qty: 1).save!(validate: false) }
  end

  test "held 는 active 예약만 (위치, 품목, 로트) 별로 합한다. 로트 없는 재고는 lot_id nil 키다" do
    lot = Lot.create!(product: @product, lot_no: "LOT-RSV")
    Reservation.create!(task: make_task, product: @product, location: @bin, qty: 5)
    Reservation.create!(task: make_task, product: @product, location: @bin, qty: 7)
    Reservation.create!(task: make_task, product: @product, lot: lot, location: @bin, qty: 3)
    Reservation.create!(task: make_task, product: @product, location: @bin, qty: 100, status: "consumed")
    Reservation.create!(task: make_task, product: @product, location: @bin, qty: 100, status: "released")

    held = Reservation.held

    assert_equal({ [@bin.id, @product.id, nil] => 12, [@bin.id, @product.id, lot.id] => 3 }, held)
    assert_equal({}, Reservation.held([Location.find_by!(code: "RAW-A-01-02").id]), "위치를 좁히면 그 위치만")
  end

  test "작업을 지우면(prune) 예약도 DB 가 같이 지운다" do
    task = make_task
    Reservation.create!(task: task, product: @product, location: @bin, qty: 5)

    Task.where(id: task.id).delete_all

    assert_equal 0, Reservation.count
  end
end
