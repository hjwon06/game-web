# 단일가 가격 결정. 시뮬레이터 규칙이다(거래소 원문은 확인하지 않았다). DB 를 읽지 않는 순수 계산이다.
# 후보 가격 = 양쪽 지정가 가격 전부 + 기준가. 후보 p 마다
#   수요 = 시장가 매수 + p 이상 지정가 매수 · 공급 = 시장가 매도 + p 이하 지정가 매도 · 체결량 = min(수요, 공급).
# 고르는 순서: 체결량 최대 → |수요 − 공급| 최소 → 기준가에 가까운 쪽 → 낮은 가격. 체결량 최대가 0 이면 체결 없음(nil).
# 가격별로 먼저 합산해 두므로 비용은 주문 수가 아니라 서로 다른 가격 수(호가 단위상 수백 단계)의 제곱이다.
module Securities
  module AuctionPrice
    module_function

    # buys · sells: [[가격 또는 nil(시장가), 잔량], ...]. 돌려주는 값은 [가격, 체결량] 또는 nil.
    def call(buys:, sells:, base_price:)
      buy_by = totals(buys)
      sell_by = totals(sells)
      prices = ((buy_by.keys + sell_by.keys).compact + [base_price]).uniq

      scored = prices.map do |price|
        demand = buy_by.sum { |p, q| p.nil? || p >= price ? q : 0 }
        supply = sell_by.sum { |p, q| p.nil? || p <= price ? q : 0 }
        { price: price, volume: [demand, supply].min, gap: (demand - supply).abs }
      end
      best = scored.min_by { |s| [-s[:volume], s[:gap], (s[:price] - base_price).abs, s[:price]] }
      best[:volume].zero? ? nil : [best[:price], best[:volume]]
    end

    def totals(rows)
      rows.each_with_object(Hash.new(0)) { |(price, qty), sum| sum[price] += qty }
    end
  end
end
