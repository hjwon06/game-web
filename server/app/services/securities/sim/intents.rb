# 투자자 봇의 하루 주문 의도. 시뮬레이터 규칙이다. 근거: 설계서 v4 §5 · §12(봇은 한 종목 한쪽만 · 장전 지정가만).
# 의도는 seed · 날짜 · Seed.plan · book(Sim::Book 아침 잔고) 만 본다. for_day 안에서 DB 를 읽지 않는다(SQL 0).
#   → 같은 seed · 같은 book 이면 단일가를 끄든 켜든 같은 의도가 나온다. 적정가는 FairValue 가 같은 입력만으로 만든다.
#   book 이 nil 이면 시드 개시 잔고(Book.opening)를 쓴다. 호출자(Runner)가 Book.as_of 로 아침 실제 잔고를 넘긴다.
# 하루 만드는 순서(날 시드 하나에서 차례로 뽑는다):
#   1. (계좌, 종목)마다 한쪽을 정한다. book 에 보유가 있는 종목만 매도 후보(50/50)이고 나머지는 매수다.
#   2. 시각 ORDERS_PER_DAY 개를 뽑아 정렬한다. PRE_OPEN_SHARE 만큼은 08:30~09:00, 나머지는 09:00~15:30(초 단위 균등).
#   3. 의도마다 종목 → 매수/매도 50/50 → 그쪽 계좌(비면 반대쪽) → 금액 → 노이즈. 장중 MARKET_SHARE 만큼은 시장가다.
#   매도 수량은 그날 (계좌, 종목)별 합이 book 보유를 넘지 않게 의도 순번 순으로 남은 보유를 깎는다. 남은 보유가 0 이면
#   다른 매도 계좌 → 없으면 매수로 바꾼다.
#   매수 수량은 그날 계좌별 합계 홀드가 book 현금을 넘지 않게 의도 순번 순으로 남은 현금을 깎는다. 홀드는 PlaceOrder 규칙이다:
#   지정가 = 가격 × 수량, 시장가 = Tick.limits(book.base).last × 수량. 모자라면 살 수 있는 수량으로, 1주도 못 사면 같은 종목의
#   다른 매수 계좌(1주 이상 살 수 있는 계좌)로 바꾸고, 그것도 없으면 그 의도를 버린다.
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

      # 휴장일 · 첫 장 이전이면 빈 목록. 시각 순이다. 30일 상한은 없다(영업일 규칙 Seed.business_day?).
      def for_day(date:, seed:, book: nil)
        return [] unless date >= Seed::FIRST_MARKET_DAY && Seed.business_day?(date)

        plan, fair = context(seed)

        Builder.new(date: date, seed: seed, plan: plan, fair: fair, book: book || Book.opening(plan: plan)).call
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
        def initialize(date:, seed:, plan:, fair:, book:)
          @date = date
          @seed = seed
          @fair = fair
          @codes = plan[:assets].select { |a| a[:kind] == "equity" }.map { |a| a[:code] }
          @investors = plan[:accounts].select { |a| a[:kind] == "investor" }.map { |a| a[:code] }
          @holdings = book.holdings.select do |(account, code), qty|
            qty.positive? && @codes.include?(code) && @investors.include?(account)
          end
          @remaining = @holdings.dup # 그날 (계좌, 종목)별 남은 보유. 매도 의도가 나올 때마다 깎는다(의도 시각 순).
          @cash = book.cash.dup      # 그날 계좌별 남은 현금. 매수 의도가 나올 때마다 홀드 금액만큼 깎는다.
          @base = book.base
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

          side, account = sellable(seq, code, account) if side == "sell"
          return nil unless account

          fair = @fair.at(asset_code: code, date: @date, minute: (sec - MARKET_OPEN_SECOND).div(60))
          price = limit_price(fair * (1 + noise), side)
          ref = market ? [Tick.floor_to_unit(fair.round), 1].max : price
          qty = [value / ref, 1].max
          if side == "sell"
            qty = take_holding(account, code, qty)
          else
            account, qty = afford(seq, code, account, market ? Tick.limits(@base.fetch(code)).last : price, qty)
            return nil unless account
          end

          Intent.new(seq: seq, at: Clock.at_minute(@date, 0) + sec, account_code: account, asset_code: code, side: side,
                     order_type: market ? "market" : "limit", price: market ? nil : price, qty: qty,
                     client_key: "sim:#{@seed}:#{@date.iso8601}:#{seq}")
        end

        # 고른 매도 계좌의 남은 보유가 0 이면 같은 종목의 남은 보유가 있는 다른 매도 계좌로, 없으면 매수 계좌로 바꾼다.
        # 바꿀 때의 추첨은 주 스트림을 건드리지 않는 순번별 Random 이라, 보유가 소진돼도 뒤 의도의 시각 · 종목은 그대로다.
        # 매수 계좌가 하나도 없으면 [매수, nil] 이고 그 의도는 건너뛴다(한쪽만 규칙을 깨느니 의도 하나를 버린다).
        def sellable(seq, code, account)
          return ["sell", account] if @remaining.fetch([account, code]).positive?

          others = @sides[code]["sell"].select { |a| @remaining.fetch([a, code]).positive? }
          return ["sell", others[swap_random(seq).rand(others.size)]] unless others.empty?

          buyers = @sides[code]["buy"]
          ["buy", (buyers[swap_random(seq).rand(buyers.size)] unless buyers.empty?)]
        end

        def take_holding(account, code, qty)
          taken = [qty, @remaining.fetch([account, code])].min
          @remaining[[account, code]] -= taken
          taken
        end

        # unit = 1주 홀드 금액(지정가 가격 · 시장가 상한가). [계좌, 수량]. 어느 계좌도 1주를 못 사면 nil 이다.
        # 바꿀 때의 추첨은 매도 바꾸기와 같은 이유로 순번별 Random(태그 "buy")이다.
        def afford(seq, code, account, unit, qty)
          bought = spend(account, unit, qty)
          return [account, bought] if bought.positive?

          others = @sides[code]["buy"].select { |a| a != account && @cash.fetch(a, 0) >= unit }
          return nil if others.empty?

          other = others[swap_random(seq, "buy").rand(others.size)]
          [other, spend(other, unit, qty)]
        end

        def spend(account, unit, qty)
          bought = [qty, @cash.fetch(account, 0) / unit].min
          @cash[account] -= bought * unit if bought.positive?
          bought
        end

        def swap_random(seq, tag = nil)
          Random.new(Digest::SHA256.hexdigest(["sim:intents:swap", @seed, @date.iso8601, seq, tag].compact.join("|")).to_i(16))
        end

        def limit_price(raw, side)
          price = side == "buy" ? Tick.floor_to_unit(raw.floor) : Tick.ceil_to_unit(raw.ceil)
          [price, 1].max
        end
      end
    end
  end
end
