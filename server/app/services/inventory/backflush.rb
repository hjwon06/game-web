module Inventory
  # 생산 증분만큼 BOM 자재를 라인 공급대(line_side)에서 일괄 출고(issue)하고 완제품 입고(produce) 1건을 만든다.
  # 자재는 lot nil 재고만 쓴다(로트 있는 재고는 시뮬레이터의 Logistics 가 로트별로 뺀다).
  # 전체가 한 트랜잭션이라 자재가 하나라도 모자라면 InsufficientStock 과 함께 전부 롤백된다.
  # 같은 (작업지시, bucket_at) 재호출은 멱등키가 같아 이동을 새로 만들지 않는다.
  class Backflush
    def self.call(**args) = new(**args).call

    def initialize(work_order:, produced_delta:, bucket_at:)
      @work_order = work_order
      @delta = BigDecimal(produced_delta.to_s)
      @bucket = bucket_at.utc.iso8601
    end

    # 만든 이동 목록(issue 들 + produce 1건). 재호출이면 기존 이동이 같은 순서로 돌아온다.
    def call
      raise ArgumentError, "produced_delta 는 음수일 수 없다: #{@delta}" if @delta.negative?
      return [] if @delta.zero?

      product = @work_order.item
      production = Location.find_by!(code: "production")
      line_side = Location.find_by!(code: "line_side")

      StockMove.transaction do
        issues = BomLine.where(product_id: product.id).order(:component_id).includes(:component).map do |bom|
          Move.call(product: bom.component, lot: nil, from: line_side, to: production,
                    qty: bom.qty_per * @delta, move_type: "issue", ref: @work_order,
                    idempotency_key: "issue:#{@work_order.id}:#{bom.component_id}:#{@bucket}")
        end
        produce = Move.call(product: product, lot: work_order_lot(product), from: production,
                            to: Location.find_by!(code: "qc"), qty: @delta, move_type: "produce",
                            ref: @work_order, idempotency_key: "produce:#{@work_order.id}:#{@bucket}")
        issues + [produce]
      end
    end

    private

    # 완제품 로트는 작업지시 코드 하나당 하나다(Inspect 가 이 로트를 받아 검사한다).
    def work_order_lot(product)
      # savepoint: 유니크 위반이 바깥 트랜잭션을 중단시키지 않게 한다.
      Lot.transaction(requires_new: true) { Lot.find_or_create_by!(product_id: product.id, lot_no: @work_order.code) }
    rescue ActiveRecord::RecordNotUnique
      Lot.find_by!(product_id: product.id, lot_no: @work_order.code)
    end
  end
end
