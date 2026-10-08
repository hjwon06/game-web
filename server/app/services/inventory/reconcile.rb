module Inventory
  # quants(캐시)와 stock_moves(원장) 합계를 (품목, 로트, 위치)별로 비교한다. 야간 검증용.
  # 한 SQL 문이라 하나의 스냅샷에서 비교한다. 비용은 stock_moves 전체 스캔 1회(이동이 수백만이면 야간에만 돌린다).
  class Reconcile
    SQL = <<~SQL.squish.freeze
      WITH ledger AS (
        SELECT product_id, COALESCE(lot_id, 0) AS lot_key, to_location_id AS location_id, SUM(qty) AS qty
          FROM stock_moves GROUP BY 1, 2, 3
        UNION ALL
        SELECT product_id, COALESCE(lot_id, 0), from_location_id, -SUM(qty)
          FROM stock_moves GROUP BY 1, 2, 3
      ), l AS (
        SELECT product_id, lot_key, location_id, SUM(qty) AS qty FROM ledger GROUP BY 1, 2, 3
      ), q AS (
        SELECT product_id, COALESCE(lot_id, 0) AS lot_key, location_id, qty FROM quants
      )
      SELECT product_id, lot_key, location_id, COALESCE(q.qty, 0) AS quant_qty, COALESCE(l.qty, 0) AS ledger_qty
        FROM q FULL OUTER JOIN l USING (product_id, lot_key, location_id)
       WHERE COALESCE(q.qty, 0) <> COALESCE(l.qty, 0)
       ORDER BY product_id, lot_key, location_id
    SQL

    def self.call = new.call

    # 불일치 목록. 일치하면 빈 배열.
    # [{ product_id:, lot_id:, location_id:, quant_qty:, ledger_qty:, diff: }]
    def call
      rows = StockMove.connection.select_all(SQL).to_a.map do |r|
        quant = BigDecimal(r["quant_qty"].to_s)
        ledger = BigDecimal(r["ledger_qty"].to_s)
        { product_id: r["product_id"], lot_id: r["lot_key"].to_i.zero? ? nil : r["lot_key"].to_i,
          location_id: r["location_id"], quant_qty: quant, ledger_qty: ledger, diff: quant - ledger }
      end
      Rails.logger.error({ event: "inventory.reconcile.mismatch", count: rows.size }.to_json) if rows.any?
      rows
    end
  end
end
