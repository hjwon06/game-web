require "test_helper"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

# 투자자 봇 의도(Sim::Intents · FairValue). 의도는 seed · 날짜 · Seed.plan 만 보므로 for_day 는 DB 를 읽지 않는다.
# 변이 검사(AC): 날 시드에서 날짜 빼기 → T1 날 시드, 한쪽 정하기 빼기(의도마다 무작위) → T2,
# 매도 누적 상한 빼기 → T2 누적 상한, 장전 시장가 허용 → T3.
class Securities::Sim::IntentsTest < ActiveSupport::TestCase
  KST = ActiveSupport::TimeZone["Asia/Seoul"]
  SEED = Securities::Sim::Config::SEED
  MON = Date.new(2026, 11, 2)
  TUE = Date.new(2026, 11, 3)
  SAT = Date.new(2026, 11, 7)
  Intents = Securities::Sim::Intents

  def day(date = MON, seed: SEED)
    Intents.for_day(date: date, seed: seed)
  end

  # client_key 와 날짜는 빼고 하루 안의 내용만 본다. 날짜가 다르면 내용도 달라야 한다.
  def shape(list)
    list.map { |i| [i.at.seconds_since_midnight, i.account_code, i.asset_code, i.side, i.order_type, i.price, i.qty] }
  end

  def pure_shape(list)
    list.map { |i| [i.at.seconds_since_midnight, i.account_code, i.asset_code, i.side, i.order_type] }
  end

  def pre_open?(intent)
    intent.at < KST.local(2026, 11, intent.at.day, 9, 0, 0)
  end

  test "T1 결정성: 같은 seed · 날짜면 같고 seed 나 날짜가 다르면 다르다" do
    first = day

    assert_equal Securities::Sim::Config::ORDERS_PER_DAY, first.size
    assert_equal first, day
    assert_equal first.map(&:at).sort, first.map(&:at), "시각 순이다"
    assert_equal first.size, first.map(&:client_key).uniq.size
    assert_equal "sim:#{SEED}:2026-11-02:0", first.first.client_key
    assert_not_equal shape(first), shape(day(seed: SEED + 1))
    assert_not_equal shape(first), shape(day(TUE))
  end

  # 가격 · 수량은 날마다 다른 적정가로 달라지므로 빼고, 무작위만으로 정해지는 모양만 비교한다.
  test "T1 날 시드: 시드나 날짜가 다르면 [초, 계좌, 종목, 매수/매도, 지정가/시장가] 가 다르다" do
    first = day

    assert_not_equal pure_shape(first), pure_shape(day(seed: SEED + 1))
    assert_not_equal pure_shape(first), pure_shape(day(TUE))
    # 매도 보유가 소진되면 계좌 · 쪽이 바뀔 수 있으니, 시각 · 종목 순서만으로도 날 시드가 날짜를 담는지 따로 본다.
    timeline = ->(list) { list.map { |i| [i.at.seconds_since_midnight, i.asset_code] } }
    assert_not_equal timeline.call(first), timeline.call(day(TUE))
    assert_not_equal timeline.call(first), timeline.call(day(seed: SEED + 1))
  end

  test "T1 주문 몇 개로 DB 를 바꾼 뒤에도 같고, 의도를 만드는 동안 SQL 이 한 번도 나가지 않는다" do
    Securities::Seed.run!(seed: SEED)
    before = day
    asset = Securities::Asset.find_by!(code: "VELEC")
    seller = Securities::Position.where(asset_id: asset.id).where("qty >= 1").order(:id).first.account
    buyer = Securities::Account.where(kind: "investor").where.not(id: seller.id).order(:id).first
    at = KST.local(2026, 11, 2, 8, 45, 0)
    Securities::PlaceOrder.call(account: seller, asset: asset, side: "sell", order_type: "limit", qty: 1, price: 72_000,
                                client_key: "t1-sell", at: at)
    Securities::PlaceOrder.call(account: buyer, asset: asset, side: "buy", order_type: "limit", qty: 1, price: 72_000,
                                client_key: "t1-buy", at: at)
    asset.update!(base_price: 90_000)

    queries = []
    callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
    after = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { day }

    assert_equal before, after
    assert_empty queries, "의도 생성이 DB 를 읽었다: #{queries.first}"
  end

  test "T1 FairValue: 날 D 의 값은 호출 순서 · 횟수와 무관하다" do
    forward = Securities::Sim::FairValue.new(seed: SEED)
    backward = Securities::Sim::FairValue.new(seed: SEED)
    days = (2..6).map { |d| Date.new(2026, 11, d) }
    pick = ->(fair, date) { %w[VELEC VGAME].map { |c| fair.at(asset_code: c, date: date, minute: 200) } }

    ahead = days.map { |d| pick.call(forward, d) }
    jumped = pick.call(backward, days.last) # 마지막 날부터 물어도 첫 장부터 차례로 계산한 값이다
    again = days.map { |d| pick.call(backward, d) }

    assert_equal ahead, again
    assert_equal ahead.last, jumped
    assert_equal 72_000.0, forward.at(asset_code: "VELEC", date: MON, minute: 0), "첫 장 시작 = 시드 기준가"
    assert_not_equal 72_000.0, forward.at(asset_code: "VELEC", date: MON, minute: 390)
    assert_not_equal Securities::Sim::FairValue.new(seed: SEED + 1).at(asset_code: "VELEC", date: TUE, minute: 5),
                     forward.at(asset_code: "VELEC", date: TUE, minute: 5)
  end

  test "T1 휴장일과 달력 밖은 빈 목록" do
    assert_empty day(SAT)
    assert_empty day(Date.new(2026, 11, 8))
    assert_empty day(Date.new(2027, 1, 4))
  end

  test "T2 한쪽만: 같은 (계좌, 종목)에 매수와 매도가 함께 없고 매도 계좌는 개시 보유가 있다" do
    plan = Securities::Seed.plan(seed: SEED)
    held = plan[:positions].to_h { |p| [[p[:account_code], p[:asset_code]], p[:qty]] }

    [MON, TUE].each do |date|
      list = day(date)
      sides = list.group_by { |i| [i.account_code, i.asset_code] }.transform_values { |v| v.map(&:side).uniq }

      assert(sides.values.all? { |s| s.size == 1 }, "한 (계좌, 종목)에 두 쪽이 섞였다: #{sides.find { |_, s| s.size > 1 }&.first}")
      assert_includes list.map(&:side), "sell", "매도 의도가 하나도 없으면 이 테스트는 한쪽만을 못 본다"
      list.select { |i| i.side == "sell" }.each do |i|
        assert_operator held.fetch([i.account_code, i.asset_code], 0), :>=, i.qty, "매도 수량이 개시 보유를 넘는다"
      end
    end
  end

  test "T2 누적 상한: 하루 (계좌, 종목)별 매도 수량 합이 개시 보유를 넘지 않는다" do
    plan = Securities::Seed.plan(seed: SEED)
    held = plan[:positions].to_h { |p| [[p[:account_code], p[:asset_code]], p[:qty]] }

    [MON, TUE].each do |date|
      sold = day(date).select { |i| i.side == "sell" }.group_by { |i| [i.account_code, i.asset_code] }
                      .transform_values { |v| v.sum(&:qty) }

      assert_not_empty sold, "매도 의도가 없으면 누적 상한을 못 본다"
      sold.each do |key, total|
        assert_operator total, :<=, held.fetch(key, 0), "#{date} #{key.join('/')} 매도 합이 개시 보유를 넘는다"
      end
    end
  end

  test "T3 장전 300개는 전부 지정가이고 장중 시장가는 10% ± 3%p 다" do
    list = day
    pre, mid = list.partition { |i| pre_open?(i) }

    assert_equal 300, pre.size
    assert(pre.all? { |i| i.order_type == "limit" && i.price.is_a?(Integer) })
    assert(pre.all? { |i| i.at >= KST.local(2026, 11, 2, 8, 30, 0) })
    assert(mid.all? { |i| i.at >= KST.local(2026, 11, 2, 9, 0, 0) && i.at < KST.local(2026, 11, 2, 15, 30, 0) })
    market = mid.select { |i| i.order_type == "market" }
    assert_in_delta 0.10, market.size.to_f / mid.size, 0.03
    assert(market.all? { |i| i.price.nil? && i.qty >= 1 })
    assert(list.select { |i| i.order_type == "limit" }.all? { |i| Securities::Tick.valid?(i.price) }, "지정가는 호가 단위다")
    assert(list.all? { |i| i.qty >= 1 })
  end
end
