# 대사. 어긋남 목록을 돌려준다(빈 배열이면 정상). 읽기만 한다. 시뮬레이터 규칙이다.
# 항목은 { kind:, ... } 해시이고 kind 는 네 가지다.
#   :position_mismatch    예탁 · 청산 계좌를 뺀 계좌 × 자산에서 원장 합(들어온 − 나간)이 positions 와 다르다.
#                         positions 행이 없으면 0 으로 센다. 예탁은 개시 잔고의 출처라 positions 가 없어 비교에서 뺀다.
#   :clearing_nonzero     청산 계좌의 자산별 원장 합이 0 이 아니다(결제는 항상 0 으로 끝난다).
#   :overdue_unsettled    settle_date 가 as_of 이하인데 결제되지 않은 체결(Available.unsettled 와 같은 정의)이다.
#   :open_hold_on_closed  끝난 주문(filled · cancelled · rejected)에 열린 홀드(released_at NULL)가 남았다.
# 항목마다 문장 하나로 읽히게 계좌 · 자산은 id 가 아니라 코드로 적는다.
# 검사 하나는 SQL 한 문장이라 그 문장 안에서는 같은 스냅숏을 본다(원장과 positions 를 한 문장에서 비교한다).
module Securities
  module Reconcile
    FINISHED = %w[filled cancelled rejected].freeze

    module_function

    def call(as_of:)
      raise ArgumentError, "as_of 는 Date" unless as_of.is_a?(Date)

      position_mismatches + clearing_nonzero + overdue_unsettled(as_of) + open_holds_on_closed
    end

    def position_mismatches
      select(<<~SQL).map do |r|
        SELECT a.code AS account_code, s.code AS asset_code,
               COALESCE(l.net, 0) AS ledger, COALESCE(p.qty, 0) AS position
          FROM (SELECT account_id, asset_id, SUM(qty) AS net
                  FROM (SELECT to_account_id AS account_id, asset_id, qty FROM ledger_entries
                        UNION ALL
                        SELECT from_account_id, asset_id, -qty FROM ledger_entries) e
                 GROUP BY account_id, asset_id) l
          FULL OUTER JOIN positions p ON p.account_id = l.account_id AND p.asset_id = l.asset_id
          JOIN accounts a ON a.id = COALESCE(l.account_id, p.account_id)
          JOIN assets s ON s.id = COALESCE(l.asset_id, p.asset_id)
         WHERE a.kind NOT IN ('depository', 'clearing')
           AND COALESCE(l.net, 0) <> COALESCE(p.qty, 0)
         ORDER BY a.code, s.code
      SQL
        { kind: :position_mismatch, account: r["account_code"], asset: r["asset_code"],
          ledger: r["ledger"].to_i, position: r["position"].to_i }
      end
    end

    def clearing_nonzero
      select(<<~SQL).map do |r|
        SELECT a.code AS account_code, s.code AS asset_code,
               SUM(CASE WHEN e.to_account_id = a.id THEN e.qty ELSE -e.qty END) AS net
          FROM ledger_entries e
          JOIN accounts a ON a.kind = 'clearing' AND a.id IN (e.to_account_id, e.from_account_id)
          JOIN assets s ON s.id = e.asset_id
         GROUP BY a.code, s.code
        HAVING SUM(CASE WHEN e.to_account_id = a.id THEN e.qty ELSE -e.qty END) <> 0
         ORDER BY a.code, s.code
      SQL
        { kind: :clearing_nonzero, account: r["account_code"], asset: r["asset_code"], net: r["net"].to_i }
      end
    end

    def overdue_unsettled(as_of)
      Available.unsettled.where("executions.settle_date <= ?", as_of).order("executions.id")
               .pluck("executions.id", "executions.settle_date").map do |id, settle_date|
        { kind: :overdue_unsettled, execution_id: id, settle_date: settle_date }
      end
    end

    def open_holds_on_closed
      Hold.joins(:order).where(released_at: nil, orders: { status: FINISHED }).order("holds.id")
          .pluck("holds.id", "holds.order_id", "orders.status", "holds.qty").map do |id, order_id, status, qty|
        { kind: :open_hold_on_closed, hold_id: id, order_id: order_id, status: status, qty: qty }
      end
    end

    def select(sql)
      Record.lease_connection.select_all(sql).to_a
    end
  end
end
