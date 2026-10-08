module Simulation
  # 입고: 발주(PO) → 리드타임 뒤 트럭 도착 → 팔레트별 하차(unload) → 하차가 끝난 팔레트마다 칸 적치(putaway) → 발주 입고 완료(Ops::Tick).
  # Runner 가 10초마다 부른다. 재고는 여기서 움직이지 않는다 — Ops::Plan 이 작업을 계획하고 Ops::Tick 이 완료 순간 이동을 만든다.
  # 그래서 재고 이동이 한 분에 몰리지 않고 팔레트 1개씩 도크·지게차 대수만큼 시간에 흩어져 생긴다.
  #
  # 무엇을 얼마나 시킬지(부족한 자재, 팔레트 수)는 예전 트럭과 같은 계산이다. 달라진 것은 그 결과로 곧바로 하차를 만들지 않고
  # 발주를 만든다는 것이다. 트럭 타이머(next_truck_at)는 "발주 판단 시각"이다. 트럭이 오는 시각은 발주의 expected_at(= 발주 + 공급사 리드타임)이다.
  #
  # 재시작 안전: 다음 발주 판단 시각이 inbound_states 1행에 있고, 한 번 부를 때마다 그 행을 잠근 트랜잭션 안에서
  # (적치 계획 + 발주 도착 + 발주 + 다음 시각 갱신)을 한다. 같은 발주가 두 번 도착하거나 같은 팔레트가 두 번 적치되지 않는다.
  class Inbound
    # 반환: { orders:, arrived:, unload:, putaway:, waiting: } (이번 호출에서 실제로 한 일. orders = 낸 발주, arrived = 도착 처리한 발주,
    # waiting 은 칸이 없어 receiving 에 남은 팔레트 수)
    def self.call(now:, logger: Rails.logger) = new(now: now, logger: logger).call

    # zone_code 아래(몇 단계든)의 칸(bin)을 코드 순으로. Logistics 의 백플러시도 이 순서로 차감한다.
    def self.bins_under(zone_code)
      tree = Location.sanitize_sql_array([<<~SQL.squish, zone_code, Location::MAX_DEPTH])
        WITH RECURSIVE tree(id, depth) AS (
          SELECT id, 0 FROM locations WHERE code = ?
          UNION ALL
          SELECT l.id, t.depth + 1 FROM locations l JOIN tree t ON l.parent_id = t.id WHERE t.depth < ?
        ) SELECT id FROM tree
      SQL
      Location.where(level: "bin").where("locations.id IN (#{tree})").order(:code)
    end

    def initialize(now:, logger:)
      @now = now.utc
      @logger = logger
      @counts = { orders: 0, arrived: 0, unload: 0, putaway: 0, waiting: 0 }
    end

    def call
      InboundState.transaction do
        state = InboundState.lock_row!(default_next_truck_at: @now + interval(Random.new(Config::SEED + @now.to_i)))
        step("putaway") { plan_putaways }
        step("arrive") { arrive_order }
        step("balance") { log_balance }
        step("order") { place_order(state) } if state.next_truck_at <= @now
      end
      @logger.info("sim inbound #{@now.iso8601} #{@counts.map { |k, v| "#{k}=#{v}" }.join(' ')}") if @counts.values.any?(&:positive?)
      @counts
    end

    private

    # 단계마다 savepoint. 실패하면 그 단계가 올린 카운트도 롤백과 함께 되돌리고, 뒤 단계는 계속한다.
    def step(name)
      snapshot = @counts.dup
      ApplicationRecord.transaction(requires_new: true) { yield }
    rescue StandardError => e
      @counts.replace(snapshot)
      @logger.error("sim inbound #{name} #{@now.iso8601}: #{e.class} #{e.message}")
    end

    def interval(rng) = rng.rand(Config::TRUCK_INTERVAL_SECONDS)

    # --- 발주 ------------------------------------------------------------------------------------

    # 도착 시각이 지난 confirmed 발주 중 가장 이른 1건을 arrived 로 바꾸고, 라인마다 팔레트 수만큼 하차를 계획한다(ref = 발주 라인).
    # 한 호출에 1건만 도착한다 — 밀린 발주가 한꺼번에 도크로 몰리지 않는다. 나머지는 다음 호출(10초 뒤)이 이어서 한다.
    # 하차 계획이 하나라도 실패하면(자원 없음, 칸 자리 없음 등) 도착 처리째 되돌아가 발주는 confirmed 로 남고 다음 호출에 다시 본다.
    def arrive_order
      po = PurchaseOrder.where(status: "confirmed").where("expected_at <= ?", @now).order(:expected_at, :id).lock.first
      return unless po

      po.update!(status: "arrived", arrived_at: @now)
      po.lines.includes(:product).order(:id).each do |line|
        lot = Lot.find_or_create_by!(product: line.product, lot_no: "R-#{@now.strftime('%Y%m%d%H%M')}-#{line.product.sku}")
        pallets = (line.qty_ordered / Config::PALLET_QTY).ceil
        pallets.times do |i|
          qty = [Config::PALLET_QTY, line.qty_ordered - (i * Config::PALLET_QTY)].min
          Ops::Plan.call(kind: "unload", product: line.product, lot: lot, qty: qty,
                         from: "supplier", to: "receiving", ref: line, earliest_at: @now, now: @now)
          @counts[:unload] += 1
        end
      end
      @counts[:arrived] += 1
    end

    # 다음 판단 시각은 예정 시각 + 간격. 오래 멈췄다 돌아와 이미 지난 시각이 되면 지금 + 간격(밀린 판단을 몰아서 하지 않는다).
    # 수요가 있는 자재가 없거나 공급사가 없거나 칸이 없으면 이번에는 발주하지 않고 다음 시각만 잡는다.
    def place_order(state)
      scheduled = state.next_truck_at
      rng = Random.new(Config::SEED + scheduled.to_i)
      product, pallets, supplier = next_load
      if product
        po = PurchaseOrder.create!(po_no: PurchaseOrder.next_po_no(@now), supplier: supplier, status: "confirmed",
                                   ordered_at: @now, expected_at: @now + supplier.lead_time_seconds)
        po.lines.create!(product: product, qty_ordered: pallets * Config::PALLET_QTY)
        @counts[:orders] += 1
      end
      following = scheduled + interval(rng)
      following = @now + interval(rng) if following <= @now
      state.update!(next_truck_at: following)
    end

    # 이번에 발주할 [자재, 팔레트 수, 공급사]. 발주할 게 없으면 nil.
    # ① 보유 분수(coverage = 보유량 / 분당 수요) 가 가장 작은 자재(수요 0 인 자재, 공급사가 없는 자재, 열린 발주가 있는 자재는 후보가 아니다).
    #    보유량에는 들어오는 중인 발주 수량이 들어 있어, 다른 자재의 순위를 가릴 때 이미 주문한 몫이 반영된다.
    #    동률이면 직전 발주와 다른 자재, 그래도 같으면 id 순.
    #    재주문점(reorder_rules)이 있는 자재는 coverage 가 min_minutes 이상이면 후보에서 빠지고, 후보가 하나도 없으면 발주하지 않는다.
    # ② 팔레트 수 = ceil(그 자재 30분 수요 / 팔레트). 재주문점이 있으면 ceil((max_minutes x 분당 수요 − 보유) / 팔레트). PALLETS_PER_TRUCK 로 자른다.
    # ③ 칸이 모자라면 남은 칸 용량만큼으로 줄인다(0 이면 발주하지 않는다).
    def next_load
      demand = demand_per_minute
      return nil if demand.empty?

      suppliers = Supplier.by_product(demand.keys)
      missing = demand.keys - suppliers.keys
      @logger.warn("sim inbound #{@now.iso8601} 공급사가 없는 자재 #{missing.sort.join(',')} 는 발주하지 않는다") if missing.any?
      # 이미 열린 발주(confirmed·arrived)가 있는 자재는 새로 발주하지 않는다. 도착해서 하차 중인 발주도 끝나야 다음 발주가 나간다.
      open = PurchaseOrderLine.joins(:purchase_order).where(purchase_orders: { status: PurchaseOrder::OPEN }).distinct.pluck(:product_id)
      demand = demand.slice(*suppliers.keys).except(*open)
      return nil if demand.empty?

      held = holdings(demand.keys)
      rules = ReorderRule.by_product(demand.keys)
      coverage = demand.to_h { |id, per_minute| [id, held.fetch(id, 0) / per_minute] }
      # 재주문점: coverage 가 min 이상인 자재는 후보가 아니다. 모두 min 이상이면 이번에는 발주하지 않는다(트럭이 계속 오지 않는다).
      coverage = coverage.reject { |id, minutes| rules[id] && minutes >= rules[id].min_minutes }
      return nil if coverage.empty?

      lowest = coverage.values.min
      tied = coverage.select { |_, minutes| minutes == lowest }.keys.sort
      last = PurchaseOrderLine.order(id: :desc).pick(:product_id)
      id = tied.find { |pid| pid != last } || tied.first

      wanted = wanted_pallets(demand.fetch(id), held.fetch(id, 0), rules[id])
      wanted = wanted.clamp(Config::PALLETS_PER_TRUCK.min, Config::PALLETS_PER_TRUCK.max)
      pallets = [wanted, free_pallets(id)].min
      pallets.positive? ? [Product.find(id), pallets, suppliers.fetch(id)] : nil
    end

    # 재주문점 규칙이 있으면 max_minutes 분어치까지 채우는 양, 없으면 FORECAST_SECONDS(30분) 수요. 팔레트로 올림.
    def wanted_pallets(per_minute, held, rule)
      need = rule ? (rule.max_minutes * per_minute) - held : per_minute * (Config::FORECAST_SECONDS / 60.0)
      (need / Config::PALLET_QTY).ceil
    end

    # 자재별 보유량 = raw 칸 + line_side + 입고대 + 아직 입고대에 닿지 않은 것.
    # 아직 입고대에 닿지 않은 것 = 하차 계획분(도착한 발주의 남은 팔레트는 전부 여기 있다) + 아직 도착하지 않은 confirmed 발주 수량.
    # 그래서 confirmed·arrived 발주 수량이 모두 한 번씩만 들어간다. arrived 발주 수량을 따로 더하면 하차 계획분과 이중으로 센다.
    # 진행 중 putaway(입고대 → 칸)·feed(칸 → line_side)는 끝나기 전까지 출발 위치에 재고가 그대로 있어 따로 더하지 않는다(더하면 이중으로 센다).
    def holdings(ids)
      in_stock = Quant.where(product_id: ids, location_id: store_location_ids + Location.where(code: "line_side").pluck(:id))
                      .group(:product_id).sum(:qty)
      receiving = Quant.where(product_id: ids, location_id: Location.where(code: "receiving").select(:id)).group(:product_id).sum(:qty)
      coming = Task.where(kind: "unload", status: %w[planned started], product_id: ids).group(:product_id).sum(:qty)
      ordered = PurchaseOrderLine.joins(:purchase_order).where(purchase_orders: { status: "confirmed" }, product_id: ids)
                                 .group(:product_id).sum(:qty_ordered)
      ids.to_h { |id| [id, in_stock.fetch(id, 0) + receiving.fetch(id, 0) + coming.fetch(id, 0) + ordered.fetch(id, 0)] }
    end

    # 이 자재 팔레트가 더 들어갈 수 있는 칸 용량(팔레트 수) - 이 자재가 이미 들어오는 중이라 칸을 차지할 팔레트(입고대 + 하차 계획분 + 도착 전 confirmed 발주).
    # 들어갈 수 있는 칸은 적치 규칙이 이 자재에 열어 둔 칸뿐이다(남의 전용 랙의 빈 칸은 세지 않는다).
    def free_pallets(product_id)
      cap = Config::PALLETS_PER_TRUCK.max
      fit = Ops::Putaway.bins(product: Product.find(product_id)).sum do |bin|
        free = if bin.products.include?(product_id) then bin.capacity - bin.used
               elsif bin.products.empty? then bin.capacity
               else 0
               end
        (free / Config::PALLET_QTY).clamp(0, cap).floor
      end
      # 들어오는 중인 양도 이 자재 몫만 뺀다. 다른 자재의 입고대·하차 계획·발주가 이 자재의 칸 여유를 깎지 않는다.
      receiving = Quant.where(product_id: product_id, location_id: Location.where(code: "receiving").select(:id)).sum(:qty)
      coming = Task.where(kind: "unload", status: %w[planned started], product_id: product_id).sum(:qty)
      ordered = PurchaseOrderLine.joins(:purchase_order).where(purchase_orders: { status: "confirmed" }, product_id: product_id).sum(:qty_ordered)
      fit - ((receiving + coming + ordered).to_f / Config::PALLET_QTY).ceil
    end

    # 칸이 생기기 전 재고가 창고 자체에 있을 수 있어 raw_store 도 함께 센다.
    def store_location_ids = Location.where(code: "raw_store").pluck(:id) + self.class.bins_under("raw_store").pluck(:id)

    # 자재별 분당 예상 소비량(running 기계의 active 작업지시 양품 × BOM).
    def demand_per_minute
      bom = BomLine.all.group_by(&:product_id)
      per_second = Hash.new(0.0)
      WorkOrder.where(status: "active").joins(:machine).where(machines: { state: "running" })
               .pluck("work_orders.product_id", "machines.code").each do |product_id, code|
        good_rate = Config.rate(code) * (1 - Config.defect_rate(code))
        bom.fetch(product_id, []).each { |line| per_second[line.component_id] += good_rate * line.qty_per }
      end
      per_second.reject { |_, v| v.zero? }.transform_values { |v| v * 60 }
    end

    # BALANCE_LOG_SECONDS 마다 한 줄: 자재별 coverage 분, 총수요/총공급(최근 10분 하차 완료량) 분당.
    def log_balance
      return unless (@now.to_i % Config::BALANCE_LOG_SECONDS).zero?

      demand = demand_per_minute
      held = holdings(demand.keys)
      skus = Product.where(id: demand.keys).pluck(:id, :sku).to_h
      coverage = demand.map { |id, per_minute| "#{skus[id]}=#{(held.fetch(id, 0) / per_minute).round(1)}min" }.join(" ")
      window = Config::BALANCE_LOG_SECONDS
      supply = Task.where(kind: "unload", status: "done", finished_at: (@now - window)..@now).sum(:qty) * 60.0 / window
      total = demand.values.sum
      ratio = total.zero? ? "-" : (supply / total).round(2)
      @logger.info("sim inbound balance #{@now.iso8601} coverage[#{coverage}] demand_per_min=#{total.round(1)} " \
                   "supply_per_min=#{supply.round(1)} supply/demand=#{ratio}")
    end

    # --- 적치 ------------------------------------------------------------------------------------

    # 하차가 끝났는데 (취소되지 않은) 적치가 없는 팔레트마다 적치를 계획한다. 칸이 없으면 receiving 에 두고 다음 호출에 다시 본다.
    def plan_putaways
      waiting = waiting_unloads
      return if waiting.empty?

      stuck = 0
      waiting.each do |unload|
        # 원자재 적치는 지게차 진입 제한을 묻지 않는다(우선순위 feed > 원자재 적치 > 완제품 적치 = pick). 제한은 Inspection·Shipping 만 건다.
        # 칸은 적치 규칙(Ops::Putaway)이 고른다. 방금 계획한 적치도 DB 에 있어 다음 팔레트의 칸 계산에 들어간다.
        bin = Ops::Putaway.choose(product: unload.product, qty: unload.qty)
        unless bin
          stuck += 1
          next
        end

        Ops::Plan.call(kind: "putaway", product: unload.product, lot: unload.lot, qty: unload.qty,
                       from: "receiving", to: bin, ref: unload, earliest_at: unload.finished_at, now: @now)
        @counts[:putaway] += 1
      end
      @counts[:waiting] = stuck
      @logger.warn("sim inbound #{@now.iso8601} 적치할 칸이 없어 receiving 에 #{stuck}팔레트 대기") if stuck.positive?
    end

    def waiting_unloads
      cutoff = @now - Config::PUTAWAY_LOOKBACK_SECONDS
      # planned_at 조건은 (status, planned_at) 인덱스 범위로 읽기 위한 것이다.
      unloads = Task.where(kind: "unload", status: "done", planned_at: (cutoff - 600)..)
                    .where("finished_at > ?", cutoff).includes(:product, :lot).order(:finished_at, :id).to_a
      return [] if unloads.empty?

      children = Task.where(kind: "putaway", ref_type: "Task", ref_id: unloads.map(&:id)).pluck(:ref_id, :status)
      cancelled, live = children.partition { |_, status| status == "cancelled" }
      covered = live.map(&:first).to_set
      cancels = cancelled.map(&:first).tally
      unloads.reject { |u| covered.include?(u.id) || cancels.fetch(u.id, 0) >= Config::MAX_PUTAWAY_CANCELS }
    end

  end
end
