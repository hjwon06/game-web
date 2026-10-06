require "test_helper"

class HudControllerTest < ActionDispatch::IntegrationTest
  NOW = Time.utc(2026, 10, 6, 12, 0, 30)

  setup do
    @m1 = Machine.create!(code: "M1", name: "절단기", state: "running")
    @m2 = Machine.create!(code: "M2", name: "조립기", state: "stopped")
    @m3 = Machine.create!(code: "M3", name: "검사기", state: "broken")
    @order = WorkOrder.create!(code: "WO-1", machine: @m1, product: "브래킷 A", target_qty: 100,
                               produced_qty: 30, status: "active")
  end

  def add_event(bucket_start, good, defect)
    ProductionEvent.create!(machine: @m1, work_order: @order, bucket_start: bucket_start,
                            bucket_end: bucket_start + 10, good_qty: good, defect_qty: defect, machine_version: 0)
  end

  test "집계가 없으면 buckets 0, 불량률 null 이고 고장 목록이 나온다" do
    travel_to(NOW) { get "/api/hud" }

    assert_response :ok
    body = response.parsed_body
    assert_equal %w[M1 M2 M3], body["machines"].map { |m| m["code"] }
    m1 = body["machines"].first
    assert_equal({ "code" => "WO-1", "product" => "브래킷 A", "target_qty" => 100, "produced_qty" => 30 },
                 m1["work_order"])
    assert_equal [0, 0], [m1["last_minute_good"], m1["last_minute_buckets"]]
    assert_nil body["machines"][1]["work_order"]
    assert_nil body["defect_ratio_10m"]
    assert_equal ["M3"], body["broken"]
  end

  test "최근 1분 합과 실제 행 수, 10분 불량률을 계산한다" do
    travel_to(NOW) do
      add_event(NOW - 10, 6, 1)
      add_event(NOW - 20, 4, 1)
      add_event(NOW - 5.minutes, 10, 0)
      get "/api/hud"
    end

    m1 = response.parsed_body["machines"].first
    assert_equal [10, 2], [m1["last_minute_good"], m1["last_minute_buckets"]]
    assert_in_delta 2.0 / 22, response.parsed_body["defect_ratio_10m"], 0.0001
  end

  test "사전 누적과 여러 이벤트가 있어도 여러 번 flush 한 뒤 지시별 produced_qty 는 good_qty 합과 같다" do
    @m2.update!(state: "running")
    @order.update!(target_qty: 10_000)
    order2 = WorkOrder.create!(code: "WO-2", machine: @m2, product: "브래킷 B", target_qty: 10_000,
                               status: "active")
    add_event(NOW - 120, 12, 1)
    add_event(NOW - 110, 18, 0)
    assert_equal 30, @order.reload.produced_qty, "사전 누적은 기존 이벤트 합과 맞춰 둔다"

    snapshot = [{ code: "M1", state: "running", version: 0 }, { code: "M2", state: "running", version: 0 }]
    rng = Random.new(1)
    flushed = 0
    5.times do |i|
      tick = Simulation::Accumulator.new
      10.times { tick.tick(snapshot, rng) }
      flushed += Simulation::Flusher.call(tick, NOW - 100 + (i * 10))
    end
    assert_equal 10, flushed, "기계 2대 × 5구간이 모두 기록돼야 한다"

    travel_to(NOW) { get "/api/hud" }

    [@order, order2].each do |order|
      assert_equal ProductionEvent.where(work_order: order).sum(:good_qty), order.reload.produced_qty, order.code
    end
    assert_operator @order.produced_qty, :>, 30
    assert_operator order2.produced_qty, :>, 0
    shown = response.parsed_body["machines"].first["work_order"]["produced_qty"]
    assert_equal @order.produced_qty, shown
  end

  test "같은 ETag 면 304 이고 데이터가 바뀌면 200 이다" do
    travel_to(NOW) do
      get "/api/hud"
      etag = response.headers["ETag"]
      assert etag.present?

      get "/api/hud", headers: { "If-None-Match" => etag }
      assert_response :not_modified

      add_event(NOW - 10, 5, 0)
      get "/api/hud", headers: { "If-None-Match" => etag }
      assert_response :ok
    end
  end
end
