# 빨리 감기 실측 진입점. 시뮬레이터 규칙이다. 빈 증권 DB 에 Seed.run! 한 뒤 첫 장 00:00 부터 영업일 days 개를 sleep 없이 돌린다.
#   - 빈 DB 가 아니면 NotEmpty 로 멈춘다. 실측은 판마다 새 DB 라서, 이어 돌리면 이전 판 주문이 섞여 숫자가 거짓이 된다.
#   - 하루씩 [그날 00:00, 다음 날 00:00) 창으로 돈다(주말도 창이 있지만 일정 · 의도가 없다). 창끼리 이어지고 하루 의도만 메모리에 둔다.
#   - 결제(T+2)가 달력을 읽으므로 마지막 영업일 뒤 SETTLE_PAD 일까지 달력 행을 채운다.
#   - 결과는 해시다. 지표(p95 · 시가와 적정가 차이)는 여기서 계산하지 않는다 — 원자료(시가 행)만 낸다.
module Securities
  module Sim
    class Fast
      class NotEmpty < StandardError; end

      SETTLE_PAD = 14

      def self.call(**args)
        new(**args).call
      end

      def initialize(days:, seed: Config::SEED, single_price: nil, runner: nil)
        raise ArgumentError, "days 는 양의 정수" unless days.is_a?(Integer) && days.positive?

        @days = days
        @seed = seed
        @single_price = single_price
        @runner = runner || Runner.new(seed: seed, single_price: single_price)
      end

      def call
        used = Seed.counts.reject { |_, n| n.zero? }
        raise NotEmpty, "증권 DB 가 비어 있지 않다: #{used}" unless used.empty?

        Seed.run!(seed: @seed)
        last = last_business_day
        Calendar.extend!(through: last + SETTLE_PAD)
        totals = (Seed::FIRST_MARKET_DAY..last).each_with_object(empty_totals) do |date, sum|
          add(sum, @runner.advance(from: Clock.at_minute(date, 0), to: Clock.at_minute(date + 1, 0)))
        end
        report(totals, last)
      end

      private

      def last_business_day
        day = Seed::FIRST_MARKET_DAY
        left = @days
        loop do
          left -= 1 if Seed.business_day?(day)
          return day if left.zero?

          day += 1
        end
      end

      def empty_totals
        { placed: 0, by_status: Hash.new(0), by_reject_reason: Hash.new(0) }
      end

      def add(sum, result)
        sum[:placed] += result.placed
        result.by_status.each { |k, v| sum[:by_status][k] += v }
        result.by_reject_reason.each { |k, v| sum[:by_reject_reason][k] += v }
      end

      # opens: 종목코드 → 날짜 순 시가 행. price 는 체결이 없거나 단일가가 꺼져 있으면 null 이다.
      def report(totals, last)
        {
          days: @days, seed: @seed, single_price: @single_price, through: last.iso8601,
          placed: totals[:placed], by_status: totals[:by_status].to_h, by_reject_reason: totals[:by_reject_reason].to_h,
          executions: Execution.count, opens: opens
        }
      end

      def opens
        codes = Asset.where(kind: "equity").pluck(:id, :code).to_h
        rows = Auction.where(session: "open").order(:trade_date, :asset_id).to_a
        codes.to_h do |id, code|
          list = rows.select { |a| a.asset_id == id }.map do |a|
            { trade_date: a.trade_date.iso8601, mode: a.mode, price: a.price, qty: a.qty, ran_at: a.ran_at.iso8601(3) }
          end
          [code, list]
        end
      end
    end
  end
end
