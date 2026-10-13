# 빨리 감기 진행기. 시뮬레이터 규칙이다. 가상 시각만 쓴다(sleep · Time.now 없음).
# advance(from:, to:) 는 가상 시각 창 [from, to) 의 일정(Schedule)과 의도(Intents)를 시간 순으로 섞어 돌린다.
#   - 의도 시각 t 마다 먼저 Schedule.run!(커서 → t + 1초)로 t 까지의 일정을 돌리고, 그 다음에 그 의도를 PlaceOrder 로 낸다.
#     그래서 시가 랜덤엔드 시각 이전 의도는 단일가에 들어가고, 이후 의도는 접속매매로 간다. 같은 시각이면 일정이 먼저다.
#   - 주문 하나 = 트랜잭션 하나(PlaceOrder 자기 것). 바깥에서 묶지 않는다. asset 은 주문마다 다시 읽는다(기준가 갱신 반영).
#   - 창 끝에서 남은 일정을 돌린다. 이어 붙인 창끼리 겹치지도 빠지지도 않는다(반열림).
#   - 같은 창을 다시 돌려도 주문이 늘지 않는다: client_key 가 날짜 · 순번이라 PlaceOrder 가 처음 주문을 돌려준다.
#     내용이 달라진 같은 키는 PlaceOrder::Conflict 로 그대로 올라온다.
# 날마다의 의도(⑥d): 날짜 D 의 의도는 D 00:00 직전까지 일정을 돌린 뒤 Book.as_of(D) 를 한 번 읽어 만든다.
#   - 창이 여러 날이어도(따라잡기) 앞 날의 체결이 DB 에 들어간 뒤 읽는다. 장부는 체결일 < D 만 보므로 D 안에서 다시 읽어도 같다.
#   - 같은 날짜의 의도는 Runner 안에서 한 번만 만든다(데몬은 tick 마다 같은 날을 다시 부른다). 창이 지나간 날짜는 버린다.
module Securities
  module Sim
    class Runner
      # 접수한 주문 수 · 주문 상태별 수 · 거절 사유별 수. 상태는 접수 직후(체결까지)의 값이다.
      Result = Struct.new(:placed, :by_status, :by_reject_reason, keyword_init: true)

      # intents: ->(date:, seed:, book:) → [Intent]. book 은 그날 아침의 Sim::Book 이다.
      def initialize(seed: Config::SEED, single_price: nil, intents: Intents.method(:for_day))
        @seed = seed
        @single_price = single_price
        @intents = intents
        @days = {}
      end

      def advance(from:, to:)
        result = Result.new(placed: 0, by_status: Hash.new(0), by_reject_reason: Hash.new(0))
        return result unless from < to

        accounts = Account.where(kind: "investor").index_by(&:code)
        cursor = from
        dates = window_dates(from, to)
        @days = @days.slice(*dates)
        dates.each do |date|
          day_start = [Clock.at_minute(date, 0), to].min
          run_schedule(cursor, day_start)
          cursor = [cursor, day_start].max
          cursor = place_day(date, from, to, cursor, accounts, result)
        end
        run_schedule(cursor, to)
        result
      end

      private

      def place_day(date, from, to, cursor, accounts, result)
        day_intents(date, from, to).each do |intent|
          upto = [intent.at + 1, to].min
          run_schedule(cursor, upto)
          cursor = [cursor, upto].max
          tally(result, place(intent, accounts.fetch(intent.account_code)))
        end
        cursor
      end

      def run_schedule(from, to)
        Schedule.run!(from: from, to: to, seed: @seed, single_price: @single_price)
      end

      def place(intent, account)
        PlaceOrder.call(account: account, asset: Asset.find_by!(code: intent.asset_code), side: intent.side,
                        order_type: intent.order_type, qty: intent.qty, price: intent.price,
                        client_key: intent.client_key, at: intent.at)
      end

      def tally(result, order)
        result.placed += 1
        result.by_status[order.status] += 1
        result.by_reject_reason[order.reject_reason] += 1 if order.reject_reason
      end

      # 창이 걸친 날짜 중 00:00 이 창 끝보다 앞선 날만. 창 끝과 같은 시각에 시작하는 날은 이 창에 의도가 없다.
      def window_dates(from, to)
        first = from.in_time_zone(Phase::ZONE).to_date
        last = to.in_time_zone(Phase::ZONE).to_date
        (first..last).select { |date| Clock.at_minute(date, 0) < to }
      end

      # 그날 의도 중 창 안의 것. 시각 순이고 같은 시각이면 공급자가 준 순서를 지킨다.
      def day_intents(date, from, to)
        list = (@days[date] ||= @intents.call(date: date, seed: @seed, book: Book.as_of(date: date, seed: @seed)))
        list.each_with_index.select { |intent, _| intent.at >= from && intent.at < to }
            .sort_by { |intent, i| [intent.at.to_r, i] }.map(&:first)
      end
    end
  end
end
