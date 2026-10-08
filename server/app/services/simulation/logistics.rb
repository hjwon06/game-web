module Simulation
  # 60초 경계마다 Runner 가 Flusher 다음에 부른다. 생산 → 자재 소비(Backflush), 입고대 적치, 자재 입고 보충.
  # 재고는 전부 Inventory::* 를 거친다. 여기서 production_events·work_orders 는 읽기만 한다.
  # 같은 분에 다시 불려도 이동이 늘지 않는다(receive·putaway 는 "sim:<종류>:<품목 id>:<분 ISO>" 키,
  # issue·produce 는 Backflush 가 (작업지시, 분) 으로 키를 만든다).
  #
  # 순서: 소비 → 적치 → 보충. 그래서 트럭이 온 분에는 소비가 막혀 있고, 다음 분에 적치되고,
  # 그다음 분부터 소비가 다시 된다.
  class Logistics
    # 반환: { backflush:, skipped:, putaway:, receive:, est_daily_moves:, inspect:, ship:, order: } (이번 호출에서 실제로 한 일)
    def self.call(now:, logger: Rails.logger) = new(now: now, logger: logger).call

    def initialize(now:, logger:)
      @minute = now.utc.beginning_of_minute
      @iso = @minute.iso8601
      @logger = logger
      @counts = { backflush: 0, skipped: 0, putaway: 0, receive: 0, est_daily_moves: 0, inspect: 0, ship: 0, order: 0 }
    end

    def call
      epoch = Config.inventory_epoch
      return @counts unless epoch

      demand = catch_up(epoch)
      materials = Product.where(id: BomLine.select(:component_id)).order(:id).to_a
      putaway(materials)
      replenish(materials, demand)
      # 검사 → 출하 → 신규 수주. 한 단계가 실패해도 그 단계만 건너뛰고 다음 단계는 한다.
      step("inspect") { inspect_qc(epoch) }
      step("ship") { ship_orders }
      step("order") { new_order }
      @logger.info("sim logistics #{@iso} #{@counts.map { |k, v| "#{k}=#{v}" }.join(' ')}")
      @counts
    end

    private

    def step(name)
      yield
    rescue StandardError => e
      @logger.error("sim logistics #{name} #{@iso}: #{e.class} #{e.message}")
    end

    # 한 항목의 실패가 같은 단계의 나머지를 막지 않게 한다.
    def guarded(name, target)
      yield
    rescue StandardError => e
      @logger.error("sim logistics #{name} #{target} #{@iso}: #{e.class} #{e.message}")
    end

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

    # --- C1 검사 -------------------------------------------------------------------------------

    # qc 에 2분 넘게 머문 로트 재고를 작업지시(로트 번호 = 작업지시 코드)별로 1번 검사한다.
    # 불량률은 그 작업지시의 EPOCH 이후 production_events 합계(defect / (good + defect)).
    def inspect_qc(epoch)
      qc = Location.find_by!(code: "qc")
      quants = Quant.where(location_id: qc.id).where.not(lot_id: nil).where("qty > 0").includes(:lot).order(:lot_id).to_a
      return if quants.empty?

      orders = WorkOrder.where(code: quants.map { |q| q.lot.lot_no }).index_by(&:code)
      recent = recent_arrivals(qc, quants.map(&:lot_id))
      events = ProductionEvent.where(work_order_id: orders.values.map(&:id), bucket_start: epoch..).group(:work_order_id)
      good = events.sum(:good_qty)
      defect = events.sum(:defect_qty)

      quants.each do |quant|
        order = orders[quant.lot.lot_no]
        next unless order && order.product_id == quant.lot.product_id

        qty = quant.qty - recent.fetch(quant.lot_id, 0)
        next unless qty.positive?

        total = good.fetch(order.id, 0) + defect.fetch(order.id, 0)
        fail_qty = total.zero? ? 0 : [(qty * defect.fetch(order.id, 0) / total).round, qty].min
        guarded("inspect", order.code) do
          Inventory::Inspect.call(lot: quant.lot, work_order: order, pass_qty: qty - fail_qty, fail_qty: fail_qty,
                                  idempotency_key: key("inspect", order))
          @counts[:inspect] += 1
        end
      end
    end

    # 로트별로 검사 한계 시각(이 분 - 2분) 이후에 qc 로 들어온 수량. 도착 시각은 produce 키의 분(시뮬레이션 시계)을 쓰고,
    # 그 형식이 아니면 created_at 을 쓴다.
    def recent_arrivals(qc, lot_ids)
      cutoff = @minute - Config::QC_DWELL_SECONDS
      StockMove.where(move_type: "produce", to_location_id: qc.id, lot_id: lot_ids)
               .pluck(:lot_id, :qty, :idempotency_key, :created_at)
               .each_with_object(Hash.new(0)) do |(lot_id, qty, k, created_at), sums|
        arrived = k[/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/]&.then { |iso| Time.iso8601(iso) } || created_at
        sums[lot_id] += qty if arrived >= cutoff
      end
    end

    # --- C2 출하 -------------------------------------------------------------------------------

    # 납기 빠른 순으로 수주 3건까지, 라인마다 fg_store 의 가장 오래된 로트에서 가능한 만큼(부분 출하).
    # 이번 분에 이미 출하한 수주는 done 이 됐어도 후보에 남겨 같은 분 재실행이 4번째 수주로 번지지 않게 한다.
    def ship_orders
      fg_store = Location.find_by!(code: "fg_store")
      stock = Quant.where(location_id: fg_store.id).where.not(lot_id: nil).where("qty > 0").order(:lot_id)
                   .pluck(:product_id, :lot_id, :qty).group_by(&:first)
                   .transform_values { |rows| rows.map { |_, lot_id, qty| [lot_id, qty] } }
      this_minute = StockMove.where(move_type: "ship").where("idempotency_key LIKE ?", "sim:ship:%:#{@iso}")
      done_now = SalesOrderLine.where(id: this_minute.select(:ref_id)).select(:sales_order_id)
      # 이번 분에 만든 수주(new_order 가 created_at 을 이 분으로 찍는다)는 다음 분부터 출하한다 — 같은 분 재실행이 새 수주를 당겨 출하하지 않게.
      orders = SalesOrder.where(status: %w[open partial]).or(SalesOrder.where(id: done_now))
                         .where.not(created_at: @minute).includes(:lines).order(Arel.sql("due_date NULLS LAST"), :id)

      served = 0
      orders.each do |order|
        break if served >= Config::SHIP_ORDERS_PER_MINUTE

        shipped = StockMove.where(move_type: "ship", ref_type: "SalesOrderLine", ref_id: order.lines.map(&:id))
                           .group(:ref_id).sum(:qty)
        shipped_any = false
        order.lines.sort_by(&:id).each do |line|
          line_key = "sim:ship:#{line.id}:#{@iso}"
          if StockMove.exists?(idempotency_key: line_key)
            shipped_any = true
            next
          end
          remaining = line.ordered_qty - shipped.fetch(line.id, 0)
          slot = (stock[line.product_id] || []).find { |_, q| q.positive? }
          next unless remaining.positive? && slot

          qty = [remaining, slot[1]].min
          guarded("ship", "line=#{line.id}") do
            Inventory::Ship.call(sales_order_line: line, lot: Lot.find(slot[0]), qty: qty, idempotency_key: line_key)
            slot[1] -= qty
            @counts[:ship] += 1
            shipped_any = true
          end
        end
        served += 1 if shipped_any
      end
    end

    # --- C3 신규 수주 --------------------------------------------------------------------------

    # 10분에 1건. 수주의 created_at 을 이 분으로 찍어 두고 "최근 10분 안에 수주가 있나"로 판단한다
    # (같은 분 재실행도 같은 검사로 막힌다).
    def new_order
      window = @minute - Config::NEW_ORDER_INTERVAL_SECONDS
      return if SalesOrder.where("created_at > ? AND created_at <= ?", window, @minute).exists?

      active = WorkOrder.where(status: "active").includes(:machine).to_a
      return if active.empty?

      rng = Random.new(Config::SEED + (@minute.to_i / 60))
      hourly = active.group_by(&:product_id).transform_values do |list|
        list.sum { |wo| Config.rate(wo.machine.code) * (1 - Config.defect_rate(wo.machine.code)) * 3600 }
      end
      product_ids = hourly.keys.sort.sample(rng.rand(1..2), random: rng)

      SalesOrder.transaction do
        order = SalesOrder.create!(so_no: next_so_no, customer: Config::CUSTOMERS[SalesOrder.count % Config::CUSTOMERS.size],
                                   due_date: (@minute + rng.rand(1..3).days).to_date, status: "open", created_at: @minute)
        product_ids.each do |product_id|
          order.lines.create!(product_id: product_id, ordered_qty: [(hourly[product_id] * rng.rand(0.5..2.0)).round, 1].max)
        end
      end
      @counts[:order] += 1
    end

    # 같은 연월 접두사(SO-YYMM-)의 마지막 번호 + 1.
    def next_so_no
      prefix = "SO-#{@minute.strftime('%y%m')}-"
      last = SalesOrder.where("so_no LIKE ?", "#{prefix}%").pluck(:so_no)
                       .filter_map { |n| n.delete_prefix(prefix)[/\A\d+\z/]&.to_i }.max || 0
      format("%s%03d", prefix, last + 1)
    end

    def key(kind, product) = "sim:#{kind}:#{product.id}:#{@iso}"
  end
end
