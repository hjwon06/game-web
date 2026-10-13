require "test_helper"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# 빨리 감기(Sim::Fast, bin/sec_sim fast 의 본체). 하루씩만 돌린다 — 실측 날 수는 bin 이 받는다.
# 변이 검사(AC): 빈 DB 검사 빼기 → "빈 DB 가 아니면 멈춘다".
class Securities::Sim::FastTest < ActiveSupport::TestCase
  SEED = Securities::Sim::Config::SEED
  MON = Date.new(2026, 11, 2)
  EQUITIES = Securities::Seed::EQUITIES.map(&:first)

  def parsed(report)
    JSON.parse(JSON.generate(report)) # bin 이 내는 JSON 한 줄과 같은 모양
  end

  test "T3 하루(단일가 켬): 다섯 종목 시가 행이 있고 placed = 그날 의도 수" do
    report = parsed(Securities::Sim::Fast.call(days: 1, seed: SEED, single_price: true))
    expected = Securities::Sim::Intents.for_day(date: MON, seed: SEED).size

    assert_equal expected, report["placed"]
    assert_equal expected, report["by_status"].values.sum
    assert_equal EQUITIES.sort, report["opens"].keys.sort
    report["opens"].each do |code, rows|
      assert_equal 1, rows.size, "#{code} 시가 행"
      row = rows.first
      assert_equal "2026-11-02", row["trade_date"]
      assert_equal "single", row["mode"]
      assert_not_nil row["ran_at"]
      assert_equal row["price"].nil?, row["qty"].zero?, "단일가는 가격과 수량이 함께 있거나 없다"
    end
    assert_operator report["executions"], :>=, 1
    assert_equal report["executions"], Securities::Execution.count
    assert_equal expected, Securities::Order.count
    assert_equal 5, Securities::Auction.where(trade_date: MON, session: "close").count, "종가도 그날 안에 돈다"
  end

  test "T3 하루(단일가 끔): 같은 의도가 접수되고 시가 행은 접속매매(sequential · 가격 없음)다" do
    report = parsed(Securities::Sim::Fast.call(days: 1, seed: SEED, single_price: false))

    assert_equal Securities::Sim::Intents.for_day(date: MON, seed: SEED).size, report["placed"]
    rows = report["opens"].values.flatten
    assert_equal 5, rows.size
    assert(rows.all? { |r| r["mode"] == "sequential" && r["price"].nil? })
  end

  test "T3 빈 DB 가 아니면 멈추고 아무것도 쓰지 않는다" do
    Securities::Seed.run!(seed: SEED)
    before = Securities::Seed.counts

    error = assert_raises(Securities::Sim::Fast::NotEmpty) { Securities::Sim::Fast.call(days: 1, seed: SEED) }

    assert_includes error.message, "비어 있지 않다"
    assert_equal before, Securities::Seed.counts
  end

  test "days 는 양의 정수" do
    assert_raises(ArgumentError) { Securities::Sim::Fast.new(days: 0) }
    assert_raises(ArgumentError) { Securities::Sim::Fast.new(days: "1") }
  end

  test "T4 primary 를 안 쓴다: fast 동안 나간 SQL 의 연결이 전부 Securities::Record 풀이다" do
    pools = []
    callback = ->(*, payload) { pools << payload[:connection]&.pool }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      Securities::Sim::Fast.call(days: 1, seed: SEED, single_price: true)
    end

    assert_operator pools.size, :>=, 100, "쿼리를 못 잡았으면 이 단언은 아무것도 못 본다"
    assert_equal [Securities::Record.connection_pool], pools.uniq
    assert_not_includes pools, ActiveRecord::Base.connection_pool
  end
end
