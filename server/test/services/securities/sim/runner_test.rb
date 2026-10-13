require "test_helper"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# 빨리 감기 진행기(Sim::Runner). 시드 데이터 위에서 실제 경로(Schedule → PlaceOrder → Auction · Match)로 돌린다.
# 변이 검사(AC): 일정을 의도 뒤에 돌리기 → T6, client_key 순번 대신 무작위 → T5.
class Securities::Sim::RunnerTest < ActiveSupport::TestCase
  KST = ActiveSupport::TimeZone["Asia/Seoul"]
  SEED = Securities::Sim::Config::SEED
  MON = Date.new(2026, 11, 2)
  Intent = Securities::Sim::Intents::Intent

  setup do
    Securities::Seed.run!(seed: SEED)
    @runner = Securities::Sim::Runner.new(seed: SEED)
  end

  def t(hour, min, sec = 0)
    KST.local(2026, 11, 2, hour, min, sec)
  end

  # 쿼리 캐시가 쓰기 전 읽기를 붙들지 않게 uncached 로 읽는다.
  def fresh(&block)
    Securities::Record.uncached(&block)
  end

  def window_intents(from, to)
    Securities::Sim::Intents.for_day(date: MON, seed: SEED).select { |i| i.at >= from && i.at < to }
  end

  def counts
    fresh do
      [Securities::Order, Securities::Execution, Securities::Hold, Securities::Auction].map(&:count)
    end
  end

  test "T4 진행: 접수 수 = 창 의도 수, 다섯 종목 시가, 체결, 자기 체결 0, 접수 시각 = 의도 시각" do
    from = t(8, 30)
    to = t(9, 5)
    expected = window_intents(from, to)

    result = @runner.advance(from: from, to: to)

    assert_operator expected.size, :>=, 300, "장전 300개는 전부 창 안이다"
    assert_equal expected.size, result.placed
    assert_equal expected.size, result.by_status.values.sum
    fresh do
      assert_equal expected.size, Securities::Order.count
      assert_equal 5, Securities::Auction.where(trade_date: MON, session: "open").count
      assert_operator Securities::Execution.count, :>=, 1
      self_trades = Securities::Execution.joins("JOIN orders b ON b.id = executions.buy_order_id")
                                         .joins("JOIN orders s ON s.id = executions.sell_order_id")
                                         .where("b.account_id = s.account_id").count
      assert_equal 0, self_trades
      accepted = Securities::Order.pluck(:client_key, :accepted_at).to_h.transform_values(&:to_i)
      assert_equal expected.to_h { |i| [i.client_key, i.at.to_i] }, accepted
    end
  end

  test "T5 재생: 같은 창을 두 번 돌려도 주문 · 체결 · 홀드 · 시가 행이 늘지 않는다" do
    from = t(8, 30)
    to = t(9, 5)

    first = @runner.advance(from: from, to: to)
    after_first = counts
    second = @runner.advance(from: from, to: to)

    assert_equal first.placed, second.placed
    assert_equal after_first, counts
    assert_operator after_first.first, :>, 0
    assert_operator after_first[1], :>=, 1
  end

  test "T5 같은 client_key 에 내용이 다르면 Conflict 가 그대로 올라온다" do
    intent = Securities::Sim::Intents.for_day(date: MON, seed: SEED).first
    from = intent.at
    to = intent.at + 1
    @runner.advance(from: from, to: to)

    changed = Intent.new(**intent.to_h, qty: intent.qty + 1)
    runner = Securities::Sim::Runner.new(seed: SEED, intents: ->(date:, seed:) { date == MON ? [changed] : [] })

    assert_raises(Securities::PlaceOrder::Conflict) { runner.advance(from: from, to: to) }
    assert_equal 1, fresh { Securities::Order.count }
  end

  # 시가 랜덤엔드 1초 전 · 1초 뒤 의도. 앞은 시가 단일가에, 뒤는 접속매매에 들어간다.
  # 장전에 매도 둘(S1 · S2)을 미리 걸어 두면 앞 매수가 S1 과 단일가로, 뒤 매수가 남은 S2 와 접속매매로 만난다.
  test "T6 순서: 시가 랜덤엔드 1초 전 의도는 단일가로, 1초 뒤 의도는 접속매매로 체결된다" do
    asset = Securities::Asset.find_by!(code: "VELEC")
    price = asset.base_price
    ended = Securities::Auction.random_end_at(trade_date: MON, asset_id: asset.id, session: "open", seed: SEED)
    holders = Securities::Position.where(asset_id: asset.id).where("qty >= 1").order(:id).limit(2).map(&:account)
    buyers = Securities::Account.where(kind: "investor").where.not(id: holders.map(&:id)).order(:id).limit(2)
    holders.each_with_index do |account, n|
      Securities::PlaceOrder.call(account: account, asset: asset, side: "sell", order_type: "limit", qty: 1,
                                  price: price, client_key: "t6-sell-#{n}", at: t(8, 45))
    end
    intents = [[-1, "t6-before"], [1, "t6-after"]].each_with_index.map do |(shift, key), n|
      Intent.new(seq: n, at: ended + shift, account_code: buyers[n].code, asset_code: asset.code, side: "buy",
                 order_type: "limit", price: price, qty: 1, client_key: key)
    end
    runner = Securities::Sim::Runner.new(seed: SEED, intents: ->(date:, seed:) { date == MON ? intents : [] })

    result = runner.advance(from: t(8, 30), to: ended + 5)

    assert_equal 2, result.placed
    fresh do
      auction = Securities::Auction.find_by!(asset_id: asset.id, trade_date: MON, session: "open")
      fills = %w[t6-before t6-after].map do |key|
        Securities::Execution.joins("JOIN orders b ON b.id = executions.buy_order_id").where("b.client_key = ?", key).to_a
      end
      assert_equal [1, 1], fills.map(&:size)
      assert_equal "single", auction.mode
      assert_equal auction.ran_at.to_i, fills[0].first.executed_at.to_i, "앞 의도는 시가 단일가 시각에 체결된다"
      assert_equal (ended + 1).to_i, fills[1].first.executed_at.to_i, "뒤 의도는 접수 시각에 접속매매로 체결된다"
      assert_equal [price, price], fills.map { |f| f.first.price }
    end
  end
end
