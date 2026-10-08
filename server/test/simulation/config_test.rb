require "test_helper"

# 생산 배율(RATE_SCALE)과 지게차 예상 가동률. Config 값을 바꿔 가동률이 0.70 을 넘기면 여기서 깨진다.
class SimulationConfigTest < ActiveSupport::TestCase
  Config = Simulation::Config

  def with_scale(value)
    original = Config::RATE_SCALE
    Config.send(:remove_const, :RATE_SCALE)
    Config.const_set(:RATE_SCALE, value)
    yield
  ensure
    Config.send(:remove_const, :RATE_SCALE)
    Config.const_set(:RATE_SCALE, original)
  end

  test "예상 지게차 가동률은 0.70 이하다" do
    assert_operator Config.forklift_load, :<=, 0.70
  end

  test "배율을 1.0 으로 되돌리면 가동률이 0.70 을 넘는다 — 위 검사가 실제로 깨질 수 있다" do
    with_scale(1.0) { assert_operator Config.forklift_load, :>, 0.70 }
  end

  test "가동률은 배율에 비례한다" do
    base = Config.forklift_load
    with_scale(Config::RATE_SCALE * 2) { assert_in_delta base * 2, Config.forklift_load, 1e-9 }
  end

  test "Config.rate 는 RATES x RATE_SCALE 이고 기계별 상대 차이를 유지한다" do
    assert_in_delta Config::RATES.fetch("M1") * Config::RATE_SCALE, Config.rate("M1"), 1e-12
    assert_in_delta Config::RATES.fetch("M5") / Config::RATES.fetch("M6"), Config.rate("M5") / Config.rate("M6"), 1e-12
    assert_in_delta Config::DEFAULT_RATE * Config::RATE_SCALE, Config.rate("없는기계"), 1e-12
  end

  test "생산량에 배율이 반영된다: M1 한 시간 누적이 RATES 그대로의 시간당 기대값보다 배율만큼 적다" do
    accumulator = Simulation::Accumulator.new
    rng = Random.new(Config::SEED)
    snapshot = [{ code: "M1", state: "running", version: 0 }]
    3600.times { accumulator.tick(snapshot, rng) }
    entry = accumulator.entry("M1")
    produced = entry.good_qty + entry.defect_qty

    expected = Config::RATES.fetch("M1") * Config::RATE_SCALE * 3600
    assert_in_delta expected, produced, expected * 0.15
    assert_operator produced, :<, Config::RATES.fetch("M1") * 3600 * 0.5, "배율 없이 RATES 그대로면 이 값을 넘는다"
  end

  test "자재 수요(demand_per_minute)에 배율이 반영된다" do
    machine = Machine.create!(code: "M1", name: "절단기", state: "running")
    comp = Product.create!(sku: "RM-SC", name: "원자재", uom: "ea", kind: "raw")
    fg = Product.create!(sku: "FG-SC", name: "완제품", uom: "ea", kind: "fg")
    BomLine.create!(product: fg, component: comp, qty_per: 1)
    WorkOrder.create!(code: "WO-SC1", machine: machine, item: fg, product: "완제품", target_qty: 100_000,
                      status: "active", started_at: Time.current)

    demand = Simulation::Inbound.new(now: Time.current, logger: Logger.new(nil)).send(:demand_per_minute)

    expected = Config.rate("M1") * (1 - Config.defect_rate("M1")) * 60
    assert_in_delta expected, demand.fetch(comp.id), 1e-9
    assert_operator demand.fetch(comp.id), :<, Config::RATES.fetch("M1") * 60 * 0.5
  end
end
