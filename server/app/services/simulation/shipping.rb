module Simulation
  # 출하: 열린 수주 라인마다 fg 칸 재고가 있으면 pick 작업(지게차)을 계획하고, 라인의 pick 이 모두 끝나 출하대(shipping)에 모이면
  # load 작업(출하 도크)을 계획한다. Runner 가 10초마다 부른다. 재고는 여기서 움직이지 않는다 —
  # Ops::Tick 이 pick 완료 순간 pick 이동(fg 칸 → shipping)을, load 완료 순간 Inventory::Ship(shipping → customer)을 만든다.
  #
  # 작업 하나는 품목 1개·로트 1개라서 load 는 수주가 아니라 수주 라인(로트별)마다 1건이다. 부분 출하를 허용한다:
  # 재고가 모자라면 있는 만큼만 pick 하고, 그만큼만 load 해 수주는 partial 이 된다.
  # pick/load 작업의 ref 는 수주 라인(SalesOrderLine)이다. 상태 기반이라 같은 시각에 다시 불려도 작업이 늘지 않는다.
  class Shipping
    # 반환: { load:, pick: } (이번 호출에서 계획한 작업 수)
    def self.call(now:, logger: Rails.logger) = new(now: now, logger: logger).call

    OPEN = %w[planned started].freeze
    LIVE = (OPEN + %w[done]).freeze
    RETENTION_WINDOW = Task::RETENTION # 이보다 오래된 done 작업은 Task.prune! 이 지운다

    # 상차 취소가 MAX 에 닿아 포기 로그를 이미 남긴 [라인 id, 로트 id]. 프로세스 메모리(재시작하면 1줄 더 남는다).
    def self.gave_up = (@gave_up ||= Set.new)

    def initialize(now:, logger:)
      @now = now.utc
      @logger = logger
      @counts = { load: 0, pick: 0 }
    end

    def call
      # 순서: load → pick. 이미 끝난 pick 의 load 가 새 pick 때문에 미뤄지지 않게 한다.
      step("load") { plan_loads }
      step("pick") { plan_picks }
      @logger.info("sim shipping #{@now.iso8601} #{@counts.map { |k, v| "#{k}=#{v}" }.join(' ')}") if @counts.values.any?(&:positive?)
      @counts
    end

    private

    # 단계마다 savepoint. 실패하면 그 단계가 올린 카운트도 롤백과 함께 되돌리고, 뒤 단계는 계속한다.
    def step(name)
      snapshot = @counts.dup
      ApplicationRecord.transaction(requires_new: true) { yield }
    rescue StandardError => e
      @counts.replace(snapshot)
      @logger.error("sim shipping #{name} #{@now.iso8601}: #{e.class} #{e.message}")
    end

    def open_lines
      SalesOrderLine.joins(:sales_order).where(sales_orders: { status: %w[open partial] })
    end

    def line_tasks(kind, line_ids, statuses)
      Task.where(kind: kind, ref_type: "SalesOrderLine", ref_id: line_ids, status: statuses)
    end

    # --- load ------------------------------------------------------------------------------------

    # pick 이 끝났고 열린 pick 이 없는 라인마다, 로트별로 (끝난 pick 합 - 취소 아닌 load 합) 이 양수면 load 를 계획한다.
    def plan_loads
      line_ids = open_lines.pluck(:id)
      return if line_ids.empty?

      picked = line_tasks("pick", line_ids, "done").where(planned_at: (@now - RETENTION_WINDOW)..).group(:ref_id, :lot_id).sum(:qty)
      return if picked.empty?

      loaded = line_tasks("load", line_ids, LIVE).group(:ref_id, :lot_id).sum(:qty)
      picking = line_tasks("pick", line_ids, OPEN).distinct.pluck(:ref_id).to_set
      lines = SalesOrderLine.where(id: picked.keys.map(&:first)).includes(:product).index_by(&:id)
      lots = Lot.where(id: picked.keys.map(&:last).compact).index_by(&:id)
      cancels = line_tasks("load", line_ids, "cancelled").group(:ref_id, :lot_id).count
      # 라인의 주문 잔량 = 주문량 - (출하한 양 + 이미 계획된 load 합). 같은 라인의 앞 로트가 방금 계획한 양도 뺀다(아래에서 차감).
      shipped = StockMove.where(move_type: "ship", ref_type: "SalesOrderLine", ref_id: line_ids).group(:ref_id).sum(:qty)
      open_loads = line_tasks("load", line_ids, OPEN).group(:ref_id).sum(:qty)

      picked.sort_by { |(line_id, lot_id), _| [line_id, lot_id || 0] }.each do |(line_id, lot_id), qty|
        waiting = qty - loaded.fetch([line_id, lot_id], 0)
        next if picking.include?(line_id) || lot_id.nil? || !waiting.positive?

        line = lines.fetch(line_id)
        # load 수량 = min(남은 pick 분, 주문 잔량). 잔량이 0 이면 계획하지 않는다(Inventory::Ship 이 OverShipment 로 취소하던 경우).
        remaining = line.ordered_qty - shipped.fetch(line_id, 0) - open_loads.fetch(line_id, 0)
        qty_to_load = [waiting, remaining].min
        next unless qty_to_load.positive?

        if cancels.fetch([line_id, lot_id], 0) >= Config::MAX_LOAD_CANCELS
          # 취소가 계속되는 라인·로트는 더 계획하지 않는다. 10초마다 같은 로그가 반복되지 않도록 (라인, 로트)당 프로세스에서 1줄만 남긴다.
          if self.class.gave_up.add?([line_id, lot_id])
            @logger.warn("sim shipping #{@now.iso8601} 수주 라인 #{line_id} 로트 #{lot_id} 상차가 #{Config::MAX_LOAD_CANCELS}회 취소돼 더 계획하지 않음")
          end
          next
        end

        Ops::Plan.call(kind: "load", product: line.product, lot: lots.fetch(lot_id), qty: qty_to_load, from: "shipping", to: "customer",
                       ref: line, earliest_at: @now)
        open_loads[line_id] = open_loads.fetch(line_id, 0) + qty_to_load
        @counts[:load] += 1
      end
    end

    # --- pick ------------------------------------------------------------------------------------

    # 납기 빠른 순 라인마다, 주문량 - (pick 했거나 출하한 양) 이 남았고 열린 pick 이 없으면 fg 재고에서 FIFO 로 PICK_QTY 단위 pick 을 계획한다.
    def plan_picks
      product_ids = stocked_product_ids
      return if product_ids.empty?

      lines = candidate_lines(product_ids).to_a
      return if lines.empty?

      line_ids = lines.map(&:id)
      picking = line_tasks("pick", line_ids, OPEN).distinct.pluck(:ref_id).to_set
      picked = line_tasks("pick", line_ids, LIVE).group(:ref_id).sum(:qty)
      shipped = StockMove.where(move_type: "ship", ref_type: "SalesOrderLine", ref_id: line_ids).group(:ref_id).sum(:qty)

      lines.each do |line|
        next if picking.include?(line.id)

        remaining = line.ordered_qty - [picked.fetch(line.id, 0), shipped.fetch(line.id, 0)].max
        Config::PICKS_PER_LINE.times do
          break unless remaining.positive?

          # 꺼낼 칸은 Ops::Removal 이 고른다: FIFO 이면서 가용(현재고 - 다른 작업의 active 예약)이 있는 (칸, 로트).
          # 합격 적치처럼 같은 칸에서 가져가려는 다른 작업이 잡은 수량도 예약에 들어 있다.
          want = [Config::PICK_QTY, remaining].min
          source = Ops::Removal.choose(product: line.product, qty: want, from_scope: "fg_store", partial: true, require_lot: true)
          break unless source

          qty = [want, source.available].min
          Ops::Plan.call(kind: "pick", product: line.product, lot: source.lot, qty: qty, from: source.location, to: "shipping",
                         ref: line, earliest_at: @now)
          remaining -= qty
          @counts[:pick] += 1
        end
      end
    end

    # fg 칸(+ 칸이 생기기 전 재고가 있을 수 있는 fg_store 자체)에 로트 있는 재고가 있는 품목 id.
    def stocked_product_ids
      place_ids = Inbound.bins_under("fg_store").pluck(:id) + Location.where(code: "fg_store").pluck(:id)
      Quant.where(location_id: place_ids).where.not(lot_id: nil).where("qty > 0").distinct.pluck(:product_id)
    end

    def candidate_lines(product_ids)
      open_lines.where(product_id: product_ids).includes(:product)
                .order(Arel.sql("sales_orders.due_date NULLS LAST"), "sales_orders.id", :id).limit(Config::SHIP_LINES_LIMIT)
    end
  end
end
