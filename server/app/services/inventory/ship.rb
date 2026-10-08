module Inventory
  # 완제품창고 → 고객 출하(ship 1건) 후 수주 상태를 다시 계산한다. 주문량 초과 출하는 막는다.
  # 수주 행을 먼저 잠가 같은 수주에 대한 동시 출하·상태 계산을 직렬화한다(잠금 순서: 수주 → quants).
  class Ship
    class OverShipment < StandardError; end

    def self.call(**args) = new(**args).call

    def initialize(sales_order_line:, lot:, qty:, idempotency_key:)
      @line = sales_order_line
      @lot = lot
      @qty = BigDecimal(qty.to_s)
      @key = idempotency_key.to_s
    end

    def call
      raise ArgumentError, "qty 는 0보다 커야 한다: #{@qty}" unless @qty.positive?
      raise ArgumentError, "lot #{@lot.id} 은 수주 라인 품목의 로트가 아니다" if @lot.product_id != @line.product_id

      StockMove.transaction do
        order = SalesOrder.lock.find(@line.sales_order_id)

        # 재실행은 초과 검사보다 먼저 돌려준다(전량 출하 뒤의 재시도가 예외가 되면 안 된다).
        existing = StockMove.find_by(idempotency_key: @key)
        next existing if existing

        shipped = shipped_by_line([@line.id])[@line.id]
        if shipped + @qty > @line.ordered_qty
          raise OverShipment, "주문량 초과: 주문 #{@line.ordered_qty.to_s('F')} / 기출하 #{shipped.to_s('F')} / 요청 #{@qty.to_s('F')}"
        end

        move = Move.call(product: @line.product, lot: @lot, from: Location.find_by!(code: "fg_store"),
                         to: Location.find_by!(code: "customer"), qty: @qty, move_type: "ship",
                         ref: @line, idempotency_key: @key)
        order.update!(status: status_for(order))
        move
      end
    end

    private

    # 라인별 출하 누계. 출하 이동의 ref 가 수주 라인이다.
    def shipped_by_line(line_ids)
      sums = StockMove.where(move_type: "ship", ref_type: "SalesOrderLine", ref_id: line_ids).group(:ref_id).sum(:qty)
      Hash.new(BigDecimal("0")).merge(sums.transform_values { |v| BigDecimal(v.to_s) })
    end

    def status_for(order)
      lines = order.lines.to_a
      shipped = shipped_by_line(lines.map(&:id))
      if lines.all? { |l| shipped[l.id] >= l.ordered_qty } then "done"
      elsif lines.any? { |l| shipped[l.id].positive? } then "partial"
      else "open"
      end
    end
  end
end
