require "test_helper"
require "stringio"

# 지게차 진입 제한: 대기열(가장 빨리 비는 지게차까지 남은 초)이 FORKLIFT_ADMIT_SECONDS 를 넘으면 pick·putaway 는 새 작업을 만들지 않고,
# feed 는 만든다. 큐가 비면 다시 만든다.
class ForkliftAdmitTest < ActiveSupport::TestCase
  Config = Simulation::Config
  M0 = Time.utc(2026, 10, 8, 12, 0, 0)

  setup do
    Ops::Plan.reseed!(3)
    @fg = Product.create!(sku: "FG-AD", name: "브래킷", uom: "ea", kind: "fg")
    @steel = Product.create!(sku: "RAW-AD", name: "강판", uom: "ea", kind: "raw")
    @log = StringIO.new
    @seq = 0
  end

  # 지게차 전부에 now + seconds 에 끝나는 일을 걸어 대기열을 그 길이로 만든다.
  def fill_forklifts(seconds)
    Resource.where(kind: "forklift").find_each do |resource|
      Task.create!(kind: "pick", status: "planned", resource: resource, product: @fg, qty: 1,
                   from_location: Location.find_by!(code: "receiving"), to_location: Location.find_by!(code: "qc"),
                   planned_at: Time.current, expected_finish_at: Time.current + seconds)
    end
  end

  def clear_forklifts = Task.where(resource: Resource.where(kind: "forklift")).delete_all

  def logger = Logger.new(@log)

  # 칸 하나는 BIN_CAPACITY 까지만 받으므로 완제품 칸 여러 개에 나눠 넣는다.
  def fg_stock(qty)
    lot = Lot.create!(product: @fg, lot_no: "LOT-AD")
    Inventory::Move.call(product: @fg, lot: lot, from: "production", to: "qc", qty: qty, move_type: "produce", ref: nil, idempotency_key: "ad-prod")
    bins = Location.where(level: "bin").where("code LIKE 'FG-%'").order(:code).pluck(:code)
    remaining = qty
    bins.each_with_index do |bin, index|
      break if remaining <= 0
      chunk = [remaining, Config::BIN_CAPACITY].min
      Inventory::Move.call(product: @fg, lot: lot, from: "qc", to: bin, qty: chunk, move_type: "qc_pass", ref: nil, idempotency_key: "ad-pass-#{index}")
      remaining -= chunk
    end
    assert_equal 0, remaining, "완제품 칸이 부족하다"
  end

  def open_order(qty)
    so = SalesOrder.create!(so_no: "SO-AD-1", customer: "한빛정공", due_date: Date.new(2026, 10, 10), status: "open")
    so.lines.create!(product: @fg, ordered_qty: qty)
  end

  def done_unload
    lot = Lot.create!(product: @steel, lot_no: "LOT-RAW-AD")
    Inventory::Move.call(product: @steel, lot: lot, from: "supplier", to: "receiving", qty: Config::PALLET_QTY, move_type: "receive",
                         ref: nil, idempotency_key: "ad-recv")
    Task.create!(kind: "unload", status: "done", resource: Resource.where(kind: "dock_in").first, product: @steel, lot: lot,
                 qty: Config::PALLET_QTY, from_location: Location.find_by!(code: "supplier"), to_location: Location.find_by!(code: "receiving"),
                 planned_at: Time.current - 60, started_at: Time.current - 60, expected_finish_at: Time.current - 30, finished_at: Time.current - 30)
  end

  test "queue_seconds: 일이 없으면 0, 모든 지게차에 일이 걸려 있으면 가장 빨리 비는 쪽까지의 초" do
    assert_equal 0, Ops::Plan.queue_seconds("forklift")

    fill_forklifts(300)
    assert_in_delta 300, Ops::Plan.queue_seconds("forklift"), 2
    assert_in_delta 300, Ops::Plan.queue_seconds("pick"), 2, "작업 종류로 물어도 같은 지게차 풀이다"

    Task.where(resource: Resource.where(kind: "forklift").order(:id).first).update_all(expected_finish_at: Time.current + 20)
    assert_in_delta 20, Ops::Plan.queue_seconds("forklift"), 2, "한 대라도 빨리 비면 그 값"

    assert_equal 0, Ops::Plan.queue_seconds("dock_out"), "다른 종류 자원은 지게차 큐와 무관하다"
  end

  test "큐가 FORKLIFT_ADMIT_SECONDS 를 넘으면 pick 을 만들지 않고 로그 1줄, 큐가 비면 다시 만든다" do
    fg_stock(3 * Config::PICK_QTY)
    open_order(3 * Config::PICK_QTY)
    fill_forklifts(Config::FORKLIFT_ADMIT_SECONDS + 120)

    result = Simulation::Shipping.call(now: M0, logger: logger)

    assert_equal 0, result[:pick]
    assert_equal 0, Task.where(kind: "pick", ref_type: "SalesOrderLine").count
    assert_equal 1, @log.string.lines.grep(/지게차 대기 .* pick 1라인 보류/).size

    clear_forklifts
    assert_operator Simulation::Shipping.call(now: M0, logger: logger)[:pick], :>, 0
  end

  test "pick 은 큐가 상한에 닿는 순간 멈춘다: 라인당 최대 건수까지 채우지 못하고 큐는 상한 + 작업 1건 안에 머문다" do
    fg_stock(20 * Config::PICK_QTY)
    open_order(20 * Config::PICK_QTY)

    picks = Simulation::Shipping.call(now: M0, logger: logger)[:pick]

    assert_operator picks, :<, Config::PICKS_PER_LINE # 2대 x 40초: 5건이면 큐 ≈ 100초라 그 전에 멈춘다
    assert_operator Ops::Plan.queue_seconds("forklift"), :<=, Config::FORKLIFT_ADMIT_SECONDS + 50
  end

  test "큐가 길면 원자재 putaway 도 만들지 않고, 큐가 비면 만든다" do
    done_unload
    fill_forklifts(Config::FORKLIFT_ADMIT_SECONDS + 120)

    result = Simulation::Inbound.new(now: Time.current, logger: logger).send(:plan_putaways)

    assert_equal 0, Task.where(kind: "putaway").count
    assert_equal 1, @log.string.lines.grep(/지게차 대기 .* 적치 1팔레트 보류/).size, result.inspect

    clear_forklifts
    Simulation::Inbound.new(now: Time.current, logger: logger).send(:plan_putaways)
    assert_equal 1, Task.where(kind: "putaway").count
  end

  test "큐가 길어도 feed 는 계획된다" do
    Location.where(code: "RAW-A-01-01").update_all(capacity_units: 1_000_000)
    lot = nil
    Inventory::Move.call(product: @steel, lot: lot, from: "supplier", to: "receiving", qty: Config::PALLET_QTY, move_type: "receive",
                         ref: nil, idempotency_key: "ad-feed-recv")
    Inventory::Move.call(product: @steel, lot: lot, from: "receiving", to: "RAW-A-01-01", qty: Config::PALLET_QTY, move_type: "putaway",
                         ref: nil, idempotency_key: "ad-feed-put")
    machine = Machine.create!(code: "M1", name: "절단기", state: "running")
    fg = Product.create!(sku: "FG-AD2", name: "완제품", uom: "ea", kind: "fg")
    BomLine.create!(product: fg, component: @steel, qty_per: 1)
    WorkOrder.create!(code: "WO-AD", machine: machine, item: fg, product: "완제품", target_qty: 100_000, status: "active", started_at: M0)
    fill_forklifts(Config::FORKLIFT_ADMIT_SECONDS + 120)

    result = Simulation::LineFeed.call(now: M0, logger: logger)

    assert_equal 1, result[:feed]
    assert_equal 1, Task.where(kind: "feed").count
  end
end
