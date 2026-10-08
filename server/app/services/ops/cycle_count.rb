module Ops
  # 순환 실사: INTERVAL_SECONDS 마다 raw·fg 칸 1개를 골라 worker 자원으로 count 작업을 계획한다. 계획만으로는 수량이 움직이지 않는다.
  # 고르는 칸 = 재고가 있는 칸 중 마지막 실사가 가장 오래된 칸(한 번도 안 센 칸이 먼저, 같으면 칸 코드 순). 이미 실사 작업이 열려 있는 칸은 뺀다.
  # 열린 putaway/feed/pick/load 가 출발지나 도착지로 걸린 칸도 뺀다. 재고가 없는 칸은 센다고 얻는 게 없고 작업 수량(> 0)도 못 채우므로 후보가 아니다.
  #
  # 작업이 끝나면(Ops::Tick 이 complete 를 부른다) 칸에 든 품목마다 cycle_counts 행을 남긴다.
  # 시뮬레이션에서는 센 수량 = 시스템 수량이라 조정이 없다. 센 수량이 다르면(complete 에 counted 를 주는 경로 — 테스트에서만 탄다)
  # adjust 이동으로 맞춘다: 모자라면 칸 -> inventory_loss, 남으면 inventory_loss -> 칸. 원장이 그대로 남으므로 Reconcile 은 계속 0 이다.
  class CycleCount
    INTERVAL_SECONDS = 600
    ZONES = %w[raw_store fg_store].freeze
    OPEN = %w[planned started].freeze
    MOVING_KINDS = %w[putaway feed pick load].freeze
    LOCK_KEY = 2_026_100_807 # pg_advisory_xact_lock: 두 프로세스가 같은 10분 구간에 실사를 두 건 계획하지 않게 한다

    # 반환: 이번 호출에서 계획한 실사 작업 수(0 또는 1).
    def self.call(now:, logger: Rails.logger) = new(now: now, logger: logger).call

    # 실사 작업이 끝났다. counted 는 { 품목 id => 센 수량 }; nil 이면 시스템 수량 그대로 센 것으로 본다.
    # 반환: 만든 adjust 이동 배열. 같은 작업으로 다시 불러도 행·이동이 늘지 않는다(행은 (작업, 품목) 유니크, 이동은 멱등키).
    def self.complete(task, at:, counted: nil)
      counted ||= {}
      bin = task.from_location
      # 칸의 quant 를 FOR UPDATE 로 잠근 뒤에 읽는다. 읽는 동안 다른 이동이 끼어들어 센 수량과 조정 수량이 어긋나지 않게 한다.
      stock = Quant.where(location_id: bin.id).where("qty > 0").order(:id).lock.includes(:lot).to_a.group_by(&:product_id)
      (stock.keys + counted.keys).uniq.sort.flat_map do |product_id|
        quants = stock.fetch(product_id, [])
        system_qty = quants.sum(BigDecimal("0"), &:qty)
        counted_qty = BigDecimal(counted.fetch(product_id, system_qty).to_s)
        ::CycleCount.find_or_create_by!(task_id: task.id, product_id: product_id) do |row|
          row.assign_attributes(location: bin, system_qty: system_qty, counted_qty: counted_qty, counted_at: at)
        end
        adjust(task, bin, Product.find(product_id), quants, counted_qty - system_qty)
      end
    end

    # 차이만큼 이동. 모자라면 재고가 많은 로트부터 덜어 내고(로트마다 이동 1건), 남으면 가장 많은 로트에 얹는다(재고가 없으면 로트 없음).
    def self.adjust(task, bin, product, quants, difference)
      return [] if difference.zero?

      if difference.positive?
        lot = quants.max_by(&:qty)&.lot
        return [move(task, product, lot, from: "inventory_loss", to: bin, qty: difference, direction: "gain")]
      end

      remaining = -difference
      quants.sort_by { |q| [-q.qty, q.id] }.filter_map do |quant|
        take = [remaining, quant.qty].min
        next unless take.positive?

        remaining -= take
        move(task, product, quant.lot, from: bin, to: "inventory_loss", qty: take, direction: "loss")
      end
    end

    def self.move(task, product, lot, from:, to:, qty:, direction:)
      Inventory::Move.call(
        product: product, lot: lot, from: from, to: to, qty: qty, move_type: "adjust", ref: task,
        idempotency_key: "adjust:task:#{task.id}:#{product.id}:#{lot&.id || 0}:#{direction}"
      )
    end
    private_class_method :adjust, :move

    def initialize(now:, logger:)
      @now = now.utc
      @logger = logger
    end

    def call
      planned = 0
      Task.transaction do
        Task.connection.execute("SELECT pg_advisory_xact_lock(#{LOCK_KEY})")
        bin = due? ? next_bin : nil
        if bin
          stocked = Quant.where(location_id: bin.id).where("qty > 0").group(:product_id).sum(:qty)
          top = stocked.max_by { |product_id, qty| [qty, -product_id] }.first
          Ops::Plan.call(kind: "count", product: Product.find(top), lot: nil, qty: stocked.values.sum, from: bin, to: "inventory_loss",
                         ref: nil, earliest_at: @now)
          @logger.info("sim cycle_count #{@now.iso8601} #{bin.code}")
          planned = 1
        end
      end
      planned
    end

    private

    # 마지막으로 계획한 실사가 INTERVAL_SECONDS 안이면 아직이다. 취소된 실사도 센다(실패해도 10분 간격은 지킨다).
    def due?
      !Task.where(kind: "count").where("planned_at > ?", @now - INTERVAL_SECONDS).exists?
    end

    def next_bin
      bins = ZONES.flat_map { |zone| Simulation::Inbound.bins_under(zone).pluck(:id, :code) }
      stocked = Quant.where(location_id: bins.map(&:first)).where("qty > 0").distinct.pluck(:location_id).to_set
      # 실사 중인 칸 + 이 칸으로 들어오거나 나가는 열린 적치·공급·피킹·상차가 있는 칸은 센 값이 곧 틀어지므로 뺀다.
      busy = Task.where(kind: "count", status: OPEN).pluck(:from_location_id).to_set
      Task.where(kind: MOVING_KINDS, status: OPEN).pluck(:from_location_id, :to_location_id).each { |ids| busy.merge(ids) }
      candidates = bins.select { |id, _| stocked.include?(id) && !busy.include?(id) }
      return nil if candidates.empty?

      last = ::CycleCount.where(location_id: candidates.map(&:first)).group(:location_id).maximum(:counted_at)
      id, = candidates.min_by { |bin_id, code| [last[bin_id] ? 1 : 0, last[bin_id]&.to_f || 0.0, code] }
      Location.find(id)
    end
  end
end
