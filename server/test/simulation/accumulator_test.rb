require "test_helper"

class AccumulatorTest < ActiveSupport::TestCase
  def snapshot(version: 0, m1: "running", m2: "stopped", m3: "broken")
    [{ code: "M1", state: m1, version: version },
     { code: "M2", state: m2, version: version },
     { code: "M3", state: m3, version: version }]
  end

  def run_ticks(count, seed: Simulation::Config::SEED)
    acc = Simulation::Accumulator.new
    rng = Random.new(seed)
    count.times { acc.tick(snapshot, rng) }
    acc
  end

  def totals(acc)
    acc.entries.transform_values { |e| [e.good_qty, e.defect_qty] }
  end

  test "같은 시드와 같은 입력이면 같은 출력이다" do
    first = totals(run_ticks(10))
    assert_equal first, totals(run_ticks(10))
    assert_operator first["M1"].sum, :>, 0, "10초 동안 한 개도 못 만들면 검사가 비어 있다"
  end

  test "stopped 와 broken 기계는 0 이고 running 만 쌓인다" do
    acc = run_ticks(30)

    assert_equal [0, 0], totals(acc)["M2"]
    assert_equal [0, 0], totals(acc)["M3"]
    assert_operator totals(acc)["M1"].sum, :>, 0
    assert_not acc.entry("M1").discarded
  end

  test "구간 중 version 이 바뀌면 폐기 표시가 붙고 이후 생산도 멈춘다" do
    acc = Simulation::Accumulator.new
    rng = Random.new(Simulation::Config::SEED)
    5.times { acc.tick(snapshot, rng) }
    before = totals(acc)["M1"]
    assert_equal 0, acc.entry("M1").version

    acc.tick(snapshot(version: 1), rng)
    acc.tick(snapshot(version: 0), rng) # 다시 돌아와도 폐기는 유지된다

    assert acc.entry("M1").discarded
    assert_equal before, totals(acc)["M1"]
  end

  test "reset! 은 구간 상태를 비운다" do
    acc = run_ticks(3)
    acc.reset!

    assert_empty acc.entries
  end
end
