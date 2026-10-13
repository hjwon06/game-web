# 아침 장부. 시뮬레이터 규칙이다. 투자자 봇이 그날 의도를 짤 때 쓰는 보유 · 현금 · 기준가의 스냅샷이다.
# as_of(date:, seed:) 가 읽는 것은 두 가지뿐이다.
#   - 시드 개시 잔고(Seed.plan 의 positions · 종목 기준가). DB 가 아니라 plan 이다.
#   - 체결일(trade_date)이 date 보다 앞선 체결(executions). 그날 · 이후 체결과 주문 · 홀드 · assets.base_price 는 읽지 않는다.
#   → 체결은 지워지지 않으므로 나중에 다시 불러도 같고, 그날 주문을 이미 낸 뒤에 불러도 같다(재생 시 Conflict 가 없다).
# 계산:
#   holdings { [계좌코드, 종목코드] => 수량 } = 개시 보유 + Σ산 수량 − Σ판 수량. 투자자 × 종목 전부(없으면 0).
#   cash     { 계좌코드 => 원 }               = 개시 현금 + Σ판 금액 − Σ산 금액(체결가 × 수량).
#   base     { 종목코드 => 기준가 }            = 체결일 < date 인 그 종목 마지막 체결(executed_at, id 최대)의 가격, 없으면 시드 기준가.
# 결제 전 체결도 센다(Available.for 와 같은 기준). 홀드는 장 마감에 전부 풀리므로 아침에는 남아 있지 않다.
# base 는 BasePrice.roll! 이 만드는 assets.base_price 와 같은 값이다(그날 마지막 체결가 · 체결이 없으면 유지).
module Securities
  module Sim
    class Book
      attr_reader :holdings, :cash, :base

      def initialize(holdings:, cash:, base:)
        @holdings = holdings
        @cash = cash
        @base = base
      end

      # plan 의 개시 잔고만으로 만든 장부. DB 를 읽지 않는다.
      def self.opening(plan:)
        investors = plan[:accounts].select { |a| a[:kind] == "investor" }.map { |a| a[:code] }
        equities = plan[:assets].select { |a| a[:kind] == "equity" }
        holdings = investors.product(equities.map { |a| a[:code] }).to_h { |key| [key, 0] }
        cash = investors.to_h { |code| [code, 0] }
        plan[:positions].each do |p|
          key = [p[:account_code], p[:asset_code]]
          if p[:asset_code] == Asset::CASH_CODE
            cash[p[:account_code]] = p[:qty] if cash.key?(p[:account_code])
          elsif holdings.key?(key)
            holdings[key] = p[:qty]
          end
        end
        new(holdings: holdings, cash: cash, base: equities.to_h { |a| [a[:code], a[:base_price]] })
      end

      # date 아침(그날 체결 전)의 장부. 체결 · 시드만 읽는다. SQL 은 3번이다.
      def self.as_of(date:, seed:)
        raise ArgumentError, "date 는 Date" unless date.is_a?(Date)

        book = opening(plan: Intents.context(seed).first)
        scope = Execution.where("executions.trade_date < ?", date)
        flows(scope, "buy_order_id").each { |account, code, qty, amount| book.apply(account, code, qty, amount) }
        flows(scope, "sell_order_id").each { |account, code, qty, amount| book.apply(account, code, -qty, -amount) }
        last_prices(scope).each { |code, price| book.base[code] = price if book.base.key?(code) }
        book
      end

      # 그 쪽(buy_order_id 면 매수자, sell_order_id 면 매도자) 계좌 · 종목별 [수량 합, 금액 합].
      def self.flows(scope, order_column)
        scope.joins("JOIN orders o ON o.id = executions.#{order_column}")
             .joins("JOIN accounts acc ON acc.id = o.account_id JOIN assets a ON a.id = executions.asset_id")
             .group("acc.code", "a.code")
             .pluck("acc.code", "a.code", Arel.sql("SUM(executions.qty)"), Arel.sql("SUM(executions.price * executions.qty)"))
             .map { |account, code, qty, amount| [account, code, qty.to_i, amount.to_i] }
      end
      private_class_method :flows

      def self.last_prices(scope)
        scope.joins(:asset)
             .order(Arel.sql("executions.asset_id, executions.executed_at DESC, executions.id DESC"))
             .pluck(Arel.sql("DISTINCT ON (executions.asset_id) assets.code"), "executions.price")
      end
      private_class_method :last_prices

      # 종목 += qty, 현금 −= amount. 산 쪽은 (+qty, +amount), 판 쪽은 (−qty, −amount) 로 부른다.
      def apply(account, code, qty, amount)
        return unless @cash.key?(account)

        @holdings[[account, code]] += qty if @holdings.key?([account, code])
        @cash[account] -= amount
      end
    end
  end
end
