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
      rates = consumption_per_second
      need = rates.transform_values { |per_second| per_second * Config::LINE_FEED_FORECAST_SECONDS }
      if need.any?
        line_side = Location.find_by!(code: "line_side")
        shortfall = short_materials(line_side, need, rates)
        plan_feeds(line_side, shortfall) if shortfall.any?
      end
      @logger.info("sim line_feed #{@now.iso8601} #{@counts.map { |k, v| "#{k}=#{v}" }.join(' ')}") if @counts.values.any?(&:positive?)
      @counts
    end

    # 수요/공급 비교(Runner 가 10분마다 로그로 남긴다): 자재 소비를 채우는 데 필요한 feed 횟수 대 지게차가 분당 할 수 있는 작업 수.
    # est_feed_per_min 이 forklift_capacity_per_min 의 절반 이하여야 putaway·pick 이 같은 지게차를 써도 feed 가 밀리지 않는다.
    def balance
      per_minute = consumption_per_second.values.sum * 60
      forklifts = Resource.where(kind: "forklift").count
      { est_feed_per_min: (per_minute / Config::PALLET_QTY).round(2),
        forklift_capacity_per_min: (forklifts * 60.0 / Config::FORKLIFT_TASK_SECONDS).round(2) }
    end

    private

    # { product_id => 부족분 }. line_side 재고 / 분당 소비(버틸 수 있는 분 수)가 작은 자재부터. 진행 중 feed 가 있는 자재는 뺀다.
    # line_side 여유(room)가 모자라 다 못 채울 때 가장 급한 자재가 먼저 채워지게 하는 순서다.
    def short_materials(line_side, need, rates)
      ids = need.keys
      on_hand = Quant.where(location_id: line_side.id, product_id: ids).group(:product_id).sum(:qty)
      feeding = Task.where(kind: "feed", status: %w[planned started], product_id: ids).distinct.pluck(:product_id).to_set
      @room = room_in(line_side)
      need.filter_map { |id, qty| [id, qty - on_hand.fetch(id, 0)] if on_hand.fetch(id, 0) < qty && !feeding.include?(id) }
          .sort_by { |id, _| [on_hand.fetch(id, 0) / (rates.fetch(id) * 60), id] }.to_h
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
        # 꺼낼 칸은 Ops::Removal 이 고른다: raw 칸(+ raw_store 자체) 중 FIFO 로 가용(현재고 - active 예약)이 있는 (칸, 로트).
        # 팔레트 1개만큼 있는 칸이 먼저고, 없으면 가용이 있는 가장 오래된 칸에서 남은 만큼이다.
        want = [Config::PALLET_QTY, @room].min
        source = want.positive? ? Ops::Removal.choose(product: products.fetch(product_id), qty: want, from_scope: "raw_store", partial: true) : nil
        qty = source && [want, source.available].min
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
