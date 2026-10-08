module Inventory
  # 검사 결과를 이동(qc_pass: qc→fg_store, qc_fail: qc→scrap)과 inspections 행으로 한 트랜잭션에 남긴다.
  # inspections.stock_move_id 가 NOT NULL + UNIQUE 라 이동 1건당 검사 1행이다(합격·불합격이 같이 있으면 2행).
  class Inspect
    def self.call(**args) = new(**args).call

    # idempotency_key 를 주면 재호출이 안전하다. 안 주면 호출마다 새 검사로 본다.
    # reserved_by_task_id: 이 검사가 어떤 inspect 작업의 완료일 때 그 작업 id(자기 예약은 가용에서 뺀다).
    def initialize(lot:, work_order:, pass_qty:, fail_qty:, idempotency_key: SecureRandom.uuid, reserved_by_task_id: nil,
                   inspected_at: nil)
      @reserved_by_task_id = reserved_by_task_id
      @inspected_at = inspected_at
      @lot = lot
      @work_order = work_order
      @pass = BigDecimal(pass_qty.to_s)
      @fail = BigDecimal(fail_qty.to_s)
      @key = idempotency_key
    end

    # 만든 Inspection 목록(pass 먼저, fail 나중)
    def call
      raise ArgumentError, "pass_qty/fail_qty 는 음수일 수 없다" if @pass.negative? || @fail.negative?
      raise ArgumentError, "pass_qty + fail_qty 는 0보다 커야 한다" unless (@pass + @fail).positive?
      raise ArgumentError, "lot #{@lot.id} 은 작업지시 #{@work_order.code} 의 품목 로트가 아니다" if @lot.product_id != @work_order.product_id

      qc = Location.find_by!(code: "qc")
      results = []
      results << ["pass", "qc_pass", @pass, Location.find_by!(code: "fg_store")] if @pass.positive?
      results << ["fail", "qc_fail", @fail, Location.find_by!(code: "scrap")] if @fail.positive?

      StockMove.transaction do
        results.map do |result, move_type, qty, dest|
          move = Move.call(product: @lot.product, lot: @lot, from: qc, to: dest, qty: qty, move_type: move_type,
                           ref: @work_order, idempotency_key: "#{move_type}:#{@key}", reserved_by_task_id: @reserved_by_task_id)
          Inspection.find_or_create_by!(stock_move_id: move.id) do |i|
            i.lot = @lot
            i.work_order = @work_order
            i.result = result
            i.qty = qty
            i.inspected_at = @inspected_at if @inspected_at
            i.defect_qty = result == "fail" ? qty : 0
          end
        end
      end
    end
  end
end
