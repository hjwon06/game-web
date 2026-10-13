# 하루 일정. 시뮬레이터 규칙이다(거래소 원문은 확인하지 않았다).
# 영업일 D 마다 settle(D 08:30 = Phase::SCHEDULE.first[1]) 1개, 종목마다 open(시가 랜덤엔드 시각) · close(종가 랜덤엔드 시각).
#   - 창은 가상 시각의 반열림 [from, to) 이다. to 와 같은 시각 일정은 다음 창 몫이라 이어 돌려도 겹치지 않는다.
#   - 순서는 시각 → 종류(settle → open → close) → 종목 id. 휴장일(business_day false · 행 없음)에는 일정이 없다.
#   - events 는 DB 를 읽기만 한다. run! 이 실행한다.
# run! 은 일정 하나가 자기 트랜잭션이다(바깥에서 묶지 않는다). close 일정은 close! 다음에 BasePrice.roll! 이고 같은 트랜잭션이다.
#   - 멱등: 시가 · 종가 행과 settled 행은 이미 있으면 그대로이고 기준가는 절대값 대입이라 같은 창을 다시 돌려도 바뀌는 행이 없다.
#   - 따라잡기: 창이 여러 날이면 날짜 순서대로 전부 돈다. AuctionRun 의 전제(종가가 날마다 돌아야 다음 날 책이 빈다)를 여기서 지킨다.
module Securities
  module Schedule
    KINDS = %i[settle open close].freeze
    # asset 은 settle 이면 nil. at 은 가상 시각(Asia/Seoul)이다.
    Event = Struct.new(:kind, :trade_date, :asset, :at)

    module_function

    def events(from:, to:, seed:)
      return [] unless from < to

      zone = Phase::ZONE
      days = MarketDay.where(business_day: true)
                      .where(trade_date: from.in_time_zone(zone).to_date..to.in_time_zone(zone).to_date)
                      .order(:trade_date).pluck(:trade_date)
      assets = Asset.where(kind: "equity").order(:id).to_a

      list = days.flat_map { |day| day_events(day, assets, seed) }
      list.select { |e| e.at >= from && e.at < to }
           .sort_by { |e| [e.at.to_r, KINDS.index(e.kind), e.asset&.id.to_i] }
    end

    def run!(from:, to:, seed:, single_price: nil)
      events(from: from, to: to, seed: seed).each do |event|
        Record.transaction { execute(event, single_price) }
      end
    end

    def day_events(day, assets, seed)
      settle = Event.new(:settle, day, nil, Clock.at_minute(day, Phase::SCHEDULE.first[1]))
      traded = assets.flat_map do |asset|
        %w[open close].map do |session|
          at = Auction.random_end_at(trade_date: day, asset_id: asset.id, session: session, seed: seed)
          Event.new(session.to_sym, day, asset, at)
        end
      end
      [settle] + traded
    end

    # 종목 객체는 events 가 한 번 읽어 일정끼리 나눠 쓰므로, 앞 일정이 바꾼 기준가를 보도록 매번 다시 읽는다.
    def execute(event, single_price)
      case event.kind
      when :settle
        Settle.call(settle_date: event.trade_date, at: event.at)
      when :open
        Auction.open!(asset: event.asset.reload, trade_date: event.trade_date, at: event.at, single_price: single_price)
      when :close
        asset = event.asset.reload
        Auction.close!(asset: asset, trade_date: event.trade_date, at: event.at, single_price: single_price)
        BasePrice.roll!(asset: asset, trade_date: event.trade_date)
      end
    end
  end
end
