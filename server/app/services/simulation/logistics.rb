module Simulation
  # 60초 경계마다 Runner 가 Flusher 다음에 부른다. 생산 → 자재 소비(Backflush), 입고대 적치, 자재 입고 보충.
  # 재고는 전부 Inventory::* 를 거친다. 여기서 production_events·work_orders 는 읽기만 한다.
  # 같은 분에 다시 불려도 이동이 늘지 않는다(receive·putaway 는 "sim:<종류>:<품목 id>:<분 ISO>" 키,
  # issue·produce 는 Backflush 가 (작업지시, 분) 으로 키를 만든다).
  #
  # 순서: 소비 → 적치 → 보충. 그래서 트럭이 온 분에는 소비가 막혀 있고, 다음 분에 적치되고,
  # 그다음 분부터 소비가 다시 된다.
  class Logistics
    # 반환: { backflush:, skipped:, putaway:, receive:, est_daily_moves: } (이번 호출에서 실제로 한 일)
    def self.call(now:, logger: Rails.logger) = new(now: now, logger: logger).call

    def initialize(now:, logger:)
      @minute = now.utc.beginning_of_minute
      @iso = @minute.iso8601
      @logger = logger
      @counts = { backflush: 0, skipped: 0, putaway: 0, receive: 0, est_daily_moves: 0 }
    end

    def call
      epoch = Config.inventory_epoch
      return @counts unless epoch

      demand = catch_up(epoch)
      materials = Product.where(id: BomLine.select(:component_id)).order(:id).to_a
      putaway(materials)
      replenish(materials, demand)
      @logger.info("sim logistics #{@iso} #{@counts.map { |k, v| "#{k}=#{v}" }.join(' ')}")
      @counts
    end

    private

    # 작업지시별 good(EPOCH 이후 production_events) - done(produce 이동) 이 양수면 그만큼 Backflush.
    # 자재가 모자란 작업지시는 이번 분을 건너뛰고, 필요했던 자재량을 돌려줘 보충 트럭에 얹는다.
    def catch_up(epoch)
      good = ProductionEvent.where(bucket_start: epoch...@minute).group(:work_order_id).sum(:good_qty)
      done = StockMove.where(move_type: "produce", ref_type: "WorkOrder", ref_id: good.keys).group(:ref_id).sum(:qty)
      orders = WorkOrder.where(id: good.keys).includes(:item).index_by(&:id)
      demand = Hash.new(0)

      good.sort.each do |order_id, good_qty|
        delta = good_qty.to_i - done.fetch(order_id, 0).to_i
        next unless delta.positive?

        backflush(orders.fetch(order_id), delta, demand)
      end
      demand
    end

    def backflush(order, delta, demand)
      Inventory::Backflush.call(work_order: order, produced_delta: delta, bucket_at: @minute)
      @counts[:backflush] += 1
    rescue Inventory::InsufficientStock
      BomLine.where(product_id: order.product_id).each { |bom| demand[bom.component_id] += bom.qty_per * delta }
      @counts[:skipped] += 1
    rescue StandardError => e # 한 작업지시 때문에 나머지를 막지 않는다
      @logger.error("sim logistics backflush #{order.code} #{@iso}: #{e.class} #{e.message}")
    end

    # 이번 분보다 앞서 받은 입고대 재고를 자재창고로. 이번 분에 받은 트럭분은 제외한다(같은 분 재실행 대비).
    def putaway(materials)
      receiving = Location.find_by!(code: "receiving")
      on_hand = Quant.where(location_id: receiving.id, lot_id: nil, product_id: materials.map(&:id)).pluck(:product_id, :qty).to_h

      materials.each do |product|
        qty = on_hand.fetch(product.id, 0) - (StockMove.find_by(idempotency_key: key("receive", product))&.qty || 0)
        next unless qty.positive?

        Inventory::Move.call(product: product, lot: nil, from: "receiving", to: "raw_store", qty: qty,
                             move_type: "putaway", ref: nil, idempotency_key: key("putaway", product))
        @counts[:putaway] += 1
      end
    end

    # 자재창고 재고 < 다음 10분 예상 소비량(+ 이번 분에 못 뺀 양) 이면 30분치(+ 못 뺀 양) 입고. 같은 자재는 5분에 1번.
    def replenish(materials, demand)
      per_second, daily_rows = consumption_per_second
      raw_store = Location.find_by!(code: "raw_store")
      on_hand = Quant.where(location_id: raw_store.id, lot_id: nil, product_id: materials.map(&:id)).pluck(:product_id, :qty).to_h
      truck_cycle = Config::REPLENISH_SECONDS - Config::FORECAST_SECONDS
      @counts[:est_daily_moves] = daily_rows + (materials.size * 2 * 86_400 / truck_cycle)

      materials.each do |product|
        backlog = demand[product.id]
        next unless on_hand.fetch(product.id, 0) < (per_second[product.id] * Config::FORECAST_SECONDS).ceil + backlog
        next if recent_truck?(product)

        qty = (per_second[product.id] * Config::REPLENISH_SECONDS).ceil + backlog
        Inventory::Move.call(product: product, lot: nil, from: "supplier", to: "receiving", qty: qty,
                             move_type: "receive", ref: nil, idempotency_key: key("receive", product))
        @counts[:receive] += 1
      end
    end

    # 이 분 포함 최근 5분(경계 제외) 안에 같은 자재 트럭이 있었나. 키의 분 ISO 는 고정 폭이라 문자열 비교가 시각 비교다.
    def recent_truck?(product)
      prefix = "sim:receive:#{product.id}:"
      StockMove.where("idempotency_key LIKE ?", "#{prefix}%")
               .where("idempotency_key > ? AND idempotency_key <= ?",
                      prefix + (@minute - Config::TRUCK_INTERVAL_SECONDS).iso8601, prefix + @iso).exists?
    end

    # 자재별 초당 예상 소비량(running 기계의 active 작업지시 기준)과, 분당 이동 행 수(issue + produce).
    def consumption_per_second
      bom = BomLine.all.group_by(&:product_id)
      per_second = Hash.new(0.0)
      rows_per_minute = 0
      WorkOrder.where(status: "active").joins(:machine).where(machines: { state: "running" })
               .pluck("work_orders.product_id", "machines.code").each do |product_id, code|
        lines = bom.fetch(product_id, [])
        good_rate = Config.rate(code) * (1 - Config.defect_rate(code))
        lines.each { |line| per_second[line.component_id] += good_rate * line.qty_per }
        rows_per_minute += lines.size + 1
      end
      [per_second, rows_per_minute * 1440]
    end

    def key(kind, product) = "sim:#{kind}:#{product.id}:#{@iso}"
  end
end
