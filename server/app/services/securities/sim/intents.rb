# 투자자 봇의 하루 주문 의도. 시뮬레이터 규칙이다. 근거: 설계서 v4 §5 · §12(봇은 한 종목 한쪽만 · 장전 지정가만).
# 의도는 seed · 날짜 · Seed.plan 만 본다. DB 의 잔고 · 체결 · 기준가 · 주문을 읽지 않는다(Asset · Position 같은 모델 조회 금지).
#   → 같은 seed 면 단일가를 끄든 켜든 같은 의도가 나온다. 적정가는 FairValue 가 같은 입력만으로 만든다.
# 하루 만드는 순서(날 시드 하나에서 차례로 뽑는다):
#   1. (계좌, 종목)마다 한쪽을 정한다. 개시 보유가 있는 종목만 매도 후보(50/50)이고 나머지는 매수다.
#   2. 시각 ORDERS_PER_DAY 개를 뽑아 정렬한다. PRE_OPEN_SHARE 만큼은 08:30~09:00, 나머지는 09:00~15:30(초 단위 균등).
#   3. 의도마다 종목 → 매수/매도 50/50 → 그쪽 계좌(비면 반대쪽) → 금액 → 노이즈. 장중 MARKET_SHARE 만큼은 시장가다.
# 지정가 = 그 분 적정가 × (1 ± NOISE)를 호가 단위로(매수 내림 · 매도 올림). 가격제한으로 자르지 않는다(엔진이 price_limit 로 거절한다).
module Securities
  module Sim
    module Intents
      Intent = Struct.new(:seq, :at, :account_code, :asset_code, :side, :order_type, :price, :qty, :client_key,
                          keyword_init: true)

      OPEN_SECOND = Phase::SCHEDULE.first[1] * 60       # 08:30
      MARKET_OPEN_SECOND = Phase::SCHEDULE.first[2] * 60 # 09:00
      CLOSE_SECOND = Phase::SCHEDULE.last[2] * 60        # 15:30

      module_function

      # 휴장일 · 달력 밖이면 빈 목록. 시각 순이다.
      def for_day(date:, seed:)
        plan, fair = context(seed)
        day = plan[:market_days].find { |d| d[:trade_date] == date }
        return [] unless day && day[:business_day]

        Builder.new(date: date, seed: seed, plan: plan, fair: fair).call
      end

      # seed 마다 plan 과 적정가 계산기를 한 번만 만든다. 둘 다 seed 만의 함수라 캐시해도 값이 바뀌지 않는다.
      def context(seed)
        @contexts ||= {}
        @contexts[seed] ||= begin
          plan = Seed.plan(seed: seed)
          [plan, FairValue.new(seed: seed, plan: plan)]
        end
      end

      class Builder
        def initialize(date:, seed:, plan:, fair:)
          @date = date
          @seed = seed
          @fair = fair
          @codes = plan[:assets].select { |a| a[:kind] == "equity" }.map { |a| a[:code] }
          @investors = plan[:accounts].select { |a| a[:kind] == "investor" }.map { |a| a[:code] }
          @holdings = plan[:positions].select { |p| @codes.include?(p[:asset_code]) && p[:qty].positive? }
                                      .to_h { |p| [[p[:account_code], p[:asset_code]], p[:qty]] }
          @random = Random.new(Digest::SHA256.hexdigest(["sim:intents", seed, date.iso8601].join("|")).to_i(16))
        end

        def call
          @sides = decide_sides
          seconds = draw_seconds
          pre_open = (Config::ORDERS_PER_DAY * Config::PRE_OPEN_SHARE).round
          market = draw_market_slots(pre_open, seconds.size)
          seconds.each_with_index.filter_map { |sec, i| build(i, sec, market.include?(i)) }
        end

        private

        # { 종목코드 => { "buy" => [계좌코드], "sell" => [계좌코드] } }. 한 (계좌, 종목)은 한쪽에만 들어간다.
        def decide_sides
          @codes.to_h do |code|
            sides = { "buy" => [], "sell" => [] }
            @investors.each do |account|
              sell = @holdings.key?([account, code]) && @random.rand(2).zero?
              sides[sell ? "sell" : "buy"] << account
            end
            [code, sides]
          end
        end

        def draw_seconds
          pre = (Config::ORDERS_PER_DAY * Config::PRE_OPEN_SHARE).round
          early = Array.new(pre) { OPEN_SECOND + @random.rand(MARKET_OPEN_SECOND - OPEN_SECOND) }
          late = Array.new(Config::ORDERS_PER_DAY - pre) do
            MARKET_OPEN_SECOND + @random.rand(CLOSE_SECOND - MARKET_OPEN_SECOND)
          end
          (early + late).sort
        end

        # 장중 의도 중 정확히 MARKET_SHARE 만큼의 순번. 장전 순번은 들어가지 않는다.
        def draw_market_slots(pre_open, total)
          count = ((total - pre_open) * Config::MARKET_SHARE).round
          (pre_open...total).to_a.sample(count, random: @random).to_set
        end

        def build(seq, sec, market)
          code = @codes[@random.rand(@codes.size)]
          side = @random.rand(2).zero? ? "buy" : "sell"
          side = side == "buy" ? "sell" : "buy" if @sides[code][side].empty?
          pool = @sides[code][side]
          account = pool[@random.rand(pool.size)] unless pool.empty?
          value = @random.rand(Config::ORDER_VALUE)
          noise = (@random.rand * 2 * Config::NOISE) - Config::NOISE
          return nil unless account

          fair = @fair.at(asset_code: code, date: @date, minute: (sec - MARKET_OPEN_SECOND).div(60))
          price = limit_price(fair * (1 + noise), side)
          ref = market ? [Tick.floor_to_unit(fair.round), 1].max : price
          qty = [value / ref, 1].max
          qty = [qty, @holdings.fetch([account, code])].min if side == "sell"

          Intent.new(seq: seq, at: Clock.at_minute(@date, 0) + sec, account_code: account, asset_code: code, side: side,
                     order_type: market ? "market" : "limit", price: market ? nil : price, qty: qty,
                     client_key: "sim:#{@seed}:#{@date.iso8601}:#{seq}")
        end

        def limit_price(raw, side)
          price = side == "buy" ? Tick.floor_to_unit(raw.floor) : Tick.ceil_to_unit(raw.ceil)
          [price, 1].max
        end
      end
    end
  end
end
