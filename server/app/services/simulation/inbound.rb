module Simulation
  # 입고: 트럭 도착 → 팔레트별 하차(unload) → 하차가 끝난 팔레트마다 칸 적치(putaway).
  # Runner 가 10초마다 부른다. 재고는 여기서 움직이지 않는다 — Ops::Plan 이 작업을 계획하고 Ops::Tick 이 완료 순간 이동을 만든다.
  # 그래서 재고 이동이 한 분에 몰리지 않고 팔레트 1개씩 도크·지게차 대수만큼 시간에 흩어져 생긴다.
  #
  # 재시작 안전: 다음 트럭 도착 시각이 inbound_states 1행에 있고, 한 번 부를 때마다 그 행을 잠근 트랜잭션 안에서
  # (적치 계획 + 트럭 도착 + 다음 시각 갱신)을 한다. 같은 트럭이 두 번 오거나 같은 팔레트가 두 번 적치되지 않는다.
  class Inbound
    # 반환: { trucks:, unload:, putaway:, waiting: } (이번 호출에서 실제로 한 일. waiting 은 칸이 없어 receiving 에 남은 팔레트 수)
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

    Bin = Struct.new(:code, :capacity, :used, :products)

    def initialize(now:, logger:)
      @now = now.utc
      @logger = logger
      @counts = { trucks: 0, unload: 0, putaway: 0, waiting: 0 }
    end

    def call
      InboundState.transaction do
        state = InboundState.lock_row!(default_next_truck_at: @now + interval(Random.new(Config::SEED + @now.to_i)))
        step("putaway") { plan_putaways }
        step("truck") { deliver_truck(state) } if state.next_truck_at <= @now
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

    # --- 트럭 ------------------------------------------------------------------------------------

    # 다음 도착 시각은 예정 시각 + 간격. 오래 멈췄다 돌아와 이미 지난 시각이 되면 지금 + 간격(밀린 트럭을 몰아 보내지 않는다).
    # 부족한 자재가 없으면 이번 트럭은 오지 않고 다음 시각만 잡는다.
    def deliver_truck(state)
      scheduled = state.next_truck_at
      rng = Random.new(Config::SEED + scheduled.to_i)
      product = most_short_material
      if product
        lot = Lot.find_or_create_by!(product: product, lot_no: "R-#{@now.strftime('%Y%m%d%H%M')}-#{product.sku}")
        rng.rand(Config::PALLETS_PER_TRUCK).times do
          Ops::Plan.call(kind: "unload", product: product, lot: lot, qty: Config::PALLET_QTY,
                         from: "supplier", to: "receiving", ref: nil, earliest_at: @now)
          @counts[:unload] += 1
        end
        @counts[:trucks] += 1
      end
      following = scheduled + interval(rng)
      following = @now + interval(rng) if following <= @now
      state.update!(next_truck_at: following)
    end

    # (칸 재고 + 입고대 + 하차 계획분) 이 다음 30분 예상 소비량에 가장 못 미치는 자재. 모자란 자재가 없으면 nil.
    def most_short_material
      need = consumption_per_second.transform_values { |per_second| per_second * Config::FORECAST_SECONDS }
      return nil if need.empty?

      ids = need.keys
      in_stock = Quant.where(product_id: ids, location_id: store_location_ids).group(:product_id).sum(:qty)
      receiving = Quant.where(product_id: ids, location_id: Location.where(code: "receiving").select(:id)).group(:product_id).sum(:qty)
      coming = Task.where(kind: "unload", status: %w[planned started], product_id: ids).group(:product_id).sum(:qty)

      shortage = need.to_h { |id, qty| [id, qty - in_stock.fetch(id, 0) - receiving.fetch(id, 0) - coming.fetch(id, 0)] }
      id, short = shortage.max_by { |pid, s| [s, -pid] }
      short.positive? ? Product.find(id) : nil
    end

    # 칸이 생기기 전 재고가 창고 자체에 있을 수 있어 raw_store 도 함께 센다.
    def store_location_ids = Location.where(code: "raw_store").pluck(:id) + self.class.bins_under("raw_store").pluck(:id)

    # 자재별 초당 예상 소비량(running 기계의 active 작업지시 기준).
    def consumption_per_second
      bom = BomLine.all.group_by(&:product_id)
      per_second = Hash.new(0.0)
      WorkOrder.where(status: "active").joins(:machine).where(machines: { state: "running" })
               .pluck("work_orders.product_id", "machines.code").each do |product_id, code|
        good_rate = Config.rate(code) * (1 - Config.defect_rate(code))
        bom.fetch(product_id, []).each { |line| per_second[line.component_id] += good_rate * line.qty_per }
      end
      per_second.reject { |_, v| v.zero? }
    end

    # --- 적치 ------------------------------------------------------------------------------------

    # 하차가 끝났는데 (취소되지 않은) 적치가 없는 팔레트마다 적치를 계획한다. 칸이 없으면 receiving 에 두고 다음 호출에 다시 본다.
    def plan_putaways
      waiting = waiting_unloads
      return if waiting.empty?

      bins = load_bins
      stuck = 0
      waiting.each do |unload|
        bin = choose_bin(bins, unload)
        unless bin
          stuck += 1
          next
        end

        Ops::Plan.call(kind: "putaway", product: unload.product, lot: unload.lot, qty: unload.qty,
                       from: "receiving", to: bin.code, ref: unload, earliest_at: unload.finished_at)
        bin.used += unload.qty
        bin.products << unload.product_id
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

    # 칸마다 (현재고 + 이미 계획된 적치) 합과 들어 있는 품목. 이번 호출 동안은 메모리에서 갱신해 팔레트마다 다시 읽지 않는다.
    def load_bins
      rows = self.class.bins_under("raw_store").pluck(:id, :code, :capacity_units)
      ids = rows.map(&:first)
      on_hand = Quant.where(location_id: ids).where("qty > 0").group(:location_id, :product_id).sum(:qty)
      planned = Task.where(kind: "putaway", status: %w[planned started], to_location_id: ids).group(:to_location_id, :product_id).sum(:qty)

      qty_by = on_hand.merge(planned) { |_, a, b| a + b }.group_by { |(loc, _), _| loc }
      rows.map do |id, code, capacity|
        mine = qty_by.fetch(id, [])
        Bin.new(code, capacity || Float::INFINITY, mine.sum { |_, qty| qty }, mine.map { |(_, product_id), _| product_id }.to_set)
      end
    end

    # ① 같은 품목이 있고 남은 용량이 팔레트 이상인 칸 중 코드 순 첫 칸 ② 빈 칸 중 코드 순 첫 칸 ③ 없으면 nil.
    def choose_bin(bins, unload)
      bins.find { |b| b.products.include?(unload.product_id) && b.capacity - b.used >= unload.qty } ||
        bins.find { |b| b.products.empty? && b.capacity >= unload.qty }
    end
  end
end
