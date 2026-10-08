module Simulation
  # 라인 공급: line_side 의 자재별 재고가 다음 10분 예상 소비량보다 적으면 raw 칸에서 line_side 로 feed 작업(지게차) 1건을 계획한다.
  # Runner 가 10초마다 부른다. 재고는 여기서 움직이지 않는다 — Ops::Plan 이 계획하고 Ops::Tick 이 완료 순간 feed 이동을 만든다.
  #
  # 상태 기반이라 같은 시각에 다시 불려도 계획이 늘지 않는다: 같은 자재의 feed 가 planned/started 면 그 자재는 건너뛴다.
  # 수량은 팔레트 1개(PALLET_QTY)이고, 고른 (칸, 로트)에 그만큼 없으면 남은 만큼이다.
  # line_side 용량(Location::LINE_SIDE_CAPACITY, 품목 무관 합)을 넘겨 완료 때 취소되지 않도록 현재고 + 진행 중 feed 를 뺀 여유까지만 계획한다.
  class LineFeed
    # 반환: { feed:, waiting: } (이번 호출에서 계획한 feed 수, 공급이 필요한데 원천 재고나 line_side 여유가 없어 못 한 자재 수)
    def self.call(now:, logger: Rails.logger) = new(now: now, logger: logger).call

    def initialize(now:, logger:)
      @now = now.utc
      @logger = logger
      @counts = { feed: 0, waiting: 0 }
    end

    def call
      need = consumption_per_second.transform_values { |per_second| per_second * Config::LINE_FEED_FORECAST_SECONDS }
      if need.any?
        line_side = Location.find_by!(code: "line_side")
        shortfall = short_materials(line_side, need)
        plan_feeds(line_side, shortfall) if shortfall.any?
      end
      @logger.info("sim line_feed #{@now.iso8601} #{@counts.map { |k, v| "#{k}=#{v}" }.join(' ')}") if @counts.values.any?(&:positive?)
      @counts
    end

    private

    # { product_id => 부족분 } 부족분 큰 순. 진행 중 feed 가 있는 자재는 뺀다.
    def short_materials(line_side, need)
      ids = need.keys
      on_hand = Quant.where(location_id: line_side.id, product_id: ids).group(:product_id).sum(:qty)
      feeding = Task.where(kind: "feed", status: %w[planned started], product_id: ids).distinct.pluck(:product_id).to_set
      @room = room_in(line_side)
      need.filter_map { |id, qty| [id, qty - on_hand.fetch(id, 0)] if on_hand.fetch(id, 0) < qty && !feeding.include?(id) }
          .sort_by { |id, short| [-short, id] }.to_h
    end

    # line_side 에 더 들어갈 수 있는 수량: 용량 - 현재고(전 품목) - 진행 중 feed(전 품목).
    def room_in(line_side)
      held = Quant.where(location_id: line_side.id).sum(:qty)
      coming = Task.where(kind: "feed", status: %w[planned started]).sum(:qty)
      (line_side.capacity_units || Float::INFINITY) - held - coming
    end

    def plan_feeds(line_side, shortfall)
      products = Product.where(id: shortfall.keys).index_by(&:id)
      shortfall.each_key do |product_id|
        source = oldest_source(product_id)
        qty = source && [Config::PALLET_QTY, source.qty, @room].min
        unless qty&.positive?
          @counts[:waiting] += 1
          next
        end

        Ops::Plan.call(kind: "feed", product: products.fetch(product_id), lot: source.lot, qty: qty,
                       from: source.location, to: line_side, ref: nil, earliest_at: @now)
        @room -= qty
        @counts[:feed] += 1
      end
    end

    # 자재가 있는 raw 칸(+ 칸이 생기기 전 재고가 있을 수 있는 raw_store 자체) 중 로트가 가장 오래된 (칸, 로트).
    # 로트 없는 재고가 가장 오래된 것이고, 로트 시각이 같으면 칸 코드 순이다.
    def oldest_source(product_id)
      place_ids = Inbound.bins_under("raw_store").pluck(:id) + Location.where(code: "raw_store").pluck(:id)
      Quant.where(product_id: product_id, location_id: place_ids).where("qty > 0").includes(:lot, :location).to_a
           .min_by { |q| [q.lot&.created_at || Time.at(0), q.location.code, q.lot_id || 0] }
    end

    # 자재별 초당 예상 소비량(running 기계의 active 작업지시 기준). Inbound 와 같은 식이다.
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
  end
end
