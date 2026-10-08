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

      picked.sort_by { |(line_id, lot_id), _| [line_id, lot_id || 0] }.each do |(line_id, lot_id), qty|
        waiting = qty - loaded.fetch([line_id, lot_id], 0)
        next if picking.include?(line_id) || lot_id.nil? || !waiting.positive?

        line = lines.fetch(line_id)
        Ops::Plan.call(kind: "load", product: line.product, lot: lots.fetch(lot_id), qty: waiting, from: "shipping", to: "customer",
                       ref: line, earliest_at: @now)
        @counts[:load] += 1
      end
    end

    # --- pick ------------------------------------------------------------------------------------

    # 납기 빠른 순 라인마다, 주문량 - (pick 했거나 출하한 양) 이 남았고 열린 pick 이 없으면 fg 재고에서 FIFO 로 PICK_QTY 단위 pick 을 계획한다.
    def plan_picks
      stock = fg_stock
      return if stock.empty?

      lines = candidate_lines(stock.map(&:product_id).uniq).to_a
      return if lines.empty?

      line_ids = lines.map(&:id)
      picking = line_tasks("pick", line_ids, OPEN).distinct.pluck(:ref_id).to_set
      picked = line_tasks("pick", line_ids, LIVE).group(:ref_id).sum(:qty)
      shipped = StockMove.where(move_type: "ship", ref_type: "SalesOrderLine", ref_id: line_ids).group(:ref_id).sum(:qty)
      reserved = Task.where(kind: "pick", status: OPEN).group(:from_location_id, :lot_id).sum(:qty)

      lines.each do |line|
        next if picking.include?(line.id)

        remaining = line.ordered_qty - [picked.fetch(line.id, 0), shipped.fetch(line.id, 0)].max
        Config::PICKS_PER_LINE.times do
          break unless remaining.positive?

          quant = stock.find { |q| q.product_id == line.product_id && q.qty - reserved.fetch([q.location_id, q.lot_id], 0) > 0 }
          break unless quant

          qty = [Config::PICK_QTY, remaining, quant.qty - reserved.fetch([quant.location_id, quant.lot_id], 0)].min
          Ops::Plan.call(kind: "pick", product: line.product, lot: quant.lot, qty: qty, from: quant.location, to: "shipping",
                         ref: line, earliest_at: @now)
          reserved[[quant.location_id, quant.lot_id]] = reserved.fetch([quant.location_id, quant.lot_id], 0) + qty
          remaining -= qty
          @counts[:pick] += 1
        end
      end
    end

    # fg 칸(+ 칸이 생기기 전 재고가 있을 수 있는 fg_store 자체)의 로트 있는 재고를 FIFO 순으로: 로트가 오래된 순, 같으면 칸 코드 순.
    def fg_stock
      place_ids = Inbound.bins_under("fg_store").pluck(:id) + Location.where(code: "fg_store").pluck(:id)
      Quant.where(location_id: place_ids).where.not(lot_id: nil).where("qty > 0").includes(:lot, :location).to_a
           .sort_by { |q| [q.lot.created_at, q.location.code, q.lot_id] }
    end

    def candidate_lines(product_ids)
      open_lines.where(product_id: product_ids).includes(:product)
                .order(Arel.sql("sales_orders.due_date NULLS LAST"), "sales_orders.id", :id).limit(Config::SHIP_LINES_LIMIT)
    end
  end
end
