module Simulation
  # 검사: qc 에 쌓인 완제품을 작업지시별로 묶어 inspect 작업(작업자)을 계획하고, 검사가 끝나면 합격분의 적치(qc → fg 칸)를 계획한다.
  # Runner 가 10초마다 부른다. 재고는 여기서 움직이지 않는다 — Ops::Tick 이 inspect 완료 순간 불량분 qc_fail(qc → scrap) 1건을,
  # 적치 완료 순간 qc_pass(qc → fg 칸) 1건을 만든다.
  #
  # 검사 시점: 작업지시의 미검사 수량이 INSPECT_BATCH_QTY 이상이거나, 그 수량 중 가장 오래된 도착분이 INSPECT_WAIT_SECONDS 를 넘었을 때.
  # 미검사 수량 = min(원장 기준(qc 로 들어온 produce 합 - 검사 작업 합), qc 현재고 - 이미 맡겨진 수량). 둘 중 작은 쪽이라
  # 검사 작업 기록이 지워져도(Task.prune!) qc 재고보다 많이 검사하지 않고, 적치가 취소돼 qc 에 남은 합격분을 다시 검사하지도 않는다.
  # 상태 기반이라 같은 시각에 다시 불려도 작업이 늘지 않는다.
  class Inspection
    # 반환: { inspect:, putaway:, waiting: } (이번 호출에서 계획한 검사·적치 수, 칸이 없어 qc 에 남은 합격분 수)
    def self.call(now:, logger: Rails.logger) = new(now: now, logger: logger).call

    # 검사에서 나오는 불량 수량: 작업지시의 EPOCH 이후 불량률(defect / (good + defect)) x 검사 수량, 반올림. Ops::Tick 이 완료 때 쓴다.
    def self.fail_qty(order, qty)
      epoch = Config.inventory_epoch&.utc
      return 0 unless epoch

      events = ProductionEvent.where(work_order_id: order.id, bucket_start: epoch..)
      defect = events.sum(:defect_qty)
      total = events.sum(:good_qty) + defect
      return 0 if total.zero?

      [(BigDecimal(qty.to_s) * defect / total).round, qty].min
    end

    # produce 키 끝의 분 ISO(시뮬레이션 시계). 그 형식이 아니면 created_at 을 UTC ISO 로 바꿔 쓴다. 고정 폭이라 문자열 비교가 시각 비교다.
    ARRIVED_AT_SQL = <<~'SQL'.squish.freeze
      COALESCE(substring(idempotency_key from '\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$'),
               to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
    SQL

    Bin = Struct.new(:code, :capacity, :used, :products)

    def initialize(now:, logger:)
      @now = now.utc
      @logger = logger
      @counts = { inspect: 0, putaway: 0, waiting: 0 }
    end

    def call
      step("inspect") { plan_inspections }
      step("putaway") { plan_putaways }
      @logger.info("sim inspection #{@now.iso8601} #{@counts.map { |k, v| "#{k}=#{v}" }.join(' ')}") if @counts.values.any?(&:positive?)
      @counts
    end

    private

    # 단계마다 savepoint. 실패하면 그 단계가 올린 카운트도 롤백과 함께 되돌리고, 뒤 단계는 계속한다.
    def step(name)
      snapshot = @counts.dup
      ApplicationRecord.transaction(requires_new: true) { yield }
    rescue StandardError => e
      @counts.replace(snapshot)
      @logger.error("sim inspection #{name} #{@now.iso8601}: #{e.class} #{e.message}")
    end

    # --- 검사 계획 -------------------------------------------------------------------------------

    def plan_inspections
      qc = Location.find_by!(code: "qc")
      stock = Quant.where(location_id: qc.id).where.not(lot_id: nil).where("qty > 0").includes(:lot).order(:lot_id).to_a
      return if stock.empty?

      orders = WorkOrder.where(code: stock.map { |q| q.lot.lot_no }).includes(:item).index_by(&:code)
      stock = stock.select { |q| (o = orders[q.lot.lot_no]) && o.product_id == q.lot.product_id }
      return if stock.empty?

      claimed = claimed_by_lot(qc, stock.map(&:lot_id))
      uninspected = uninspected_by_order(qc, orders.values.map(&:id))
      stock.each do |quant|
        order = orders.fetch(quant.lot.lot_no)
        pending = [uninspected.fetch(order.id, 0), quant.qty - claimed.fetch(quant.lot_id, 0)].min
        next unless pending.positive? && due?(qc, quant.lot, pending)

        Ops::Plan.call(kind: "inspect", product: order.item, lot: quant.lot, qty: [pending, Location::BIN_CAPACITY].min,
                       from: qc, to: "fg_store", ref: order, earliest_at: @now)
        @counts[:inspect] += 1
      end
    end

    # { lot_id => qc 재고 중 이미 맡겨진 수량 }: 진행 중 검사 + qc 에서 나가려는 적치(합격분).
    def claimed_by_lot(qc, lot_ids)
      open = %w[planned started]
      inspecting = Task.where(kind: "inspect", status: open, lot_id: lot_ids).group(:lot_id).sum(:qty)
      leaving = Task.where(kind: "putaway", status: open, from_location_id: qc.id, lot_id: lot_ids).group(:lot_id).sum(:qty)
      inspecting.merge(leaving) { |_, a, b| a + b }
    end

    # { 작업지시 id => qc 로 들어온 양 - 검사 작업(취소 제외)에 맡긴 양 }
    def uninspected_by_order(qc, order_ids)
      produced = StockMove.where(move_type: "produce", ref_type: "WorkOrder", ref_id: order_ids, to_location_id: qc.id)
                          .group(:ref_id).sum(:qty)
      inspected = Task.where(kind: "inspect", ref_type: "WorkOrder", ref_id: order_ids, status: %w[planned started done])
                      .group(:ref_id).sum(:qty)
      produced.to_h { |id, qty| [id, qty - inspected.fetch(id, 0)] }
    end

    def due?(qc, lot, pending)
      pending >= Config::INSPECT_BATCH_QTY || oldest_arrival(qc, lot, pending) <= @now - Config::INSPECT_WAIT_SECONDS
    end

    # 미검사 수량(= 가장 최근에 도착한 pending 만큼)에서 가장 오래된 도착분의 시각. 먼저 도착한 것부터 검사됐다고 본다.
    def oldest_arrival(qc, lot, pending)
      rows = StockMove.where(move_type: "produce", to_location_id: qc.id, lot_id: lot.id)
                      .order(id: :desc).limit(200).pluck(:qty, Arel.sql(ARRIVED_AT_SQL))
      covered = 0
      oldest = rows.last&.last
      rows.each do |qty, arrived|
        covered += qty
        oldest = arrived
        break if covered >= pending
      end
      oldest ? Time.iso8601(oldest) : @now
    end

    # --- 합격분 적치 계획 ------------------------------------------------------------------------

    # 검사가 끝났는데 (취소되지 않은) 적치가 없는 작업마다 합격분(검사 수량 - 불량 이동)의 적치를 계획한다. 칸이 없으면 qc 에 두고 다음 호출에 다시 본다.
    def plan_putaways
      waiting = waiting_inspections
      return if waiting.empty?

      bins = load_bins
      stuck = 0
      waiting.each do |task|
        pass_qty = task.qty - (task.stock_move&.qty || 0)
        next unless pass_qty.positive?

        bin = choose_bin(bins, task.product_id, pass_qty)
        unless bin
          stuck += 1
          next
        end

        Ops::Plan.call(kind: "putaway", product: task.product, lot: task.lot, qty: pass_qty, from: "qc", to: bin.code,
                       ref: task, earliest_at: task.finished_at)
        bin.used += pass_qty
        bin.products << task.product_id
        @counts[:putaway] += 1
      end
      @counts[:waiting] = stuck
      @logger.warn("sim inspection #{@now.iso8601} 적치할 완제품 칸이 없어 qc 에 #{stuck}건 대기") if stuck.positive?
    end

    def waiting_inspections
      cutoff = @now - Config::INSPECT_LOOKBACK_SECONDS
      # planned_at 조건은 (status, planned_at) 인덱스 범위로 읽기 위한 것이다.
      done = Task.where(kind: "inspect", status: "done", planned_at: (cutoff - 600)..)
                 .where("finished_at > ?", cutoff).includes(:product, :lot, :stock_move).order(:finished_at, :id).to_a
      return [] if done.empty?

      children = Task.where(kind: "putaway", ref_type: "Task", ref_id: done.map(&:id)).pluck(:ref_id, :status)
      cancelled, live = children.partition { |_, status| status == "cancelled" }
      covered = live.map(&:first).to_set
      cancels = cancelled.map(&:first).tally
      done.reject { |t| covered.include?(t.id) || cancels.fetch(t.id, 0) >= Config::MAX_PUTAWAY_CANCELS }
    end

    # 칸마다 (현재고 + 이미 계획된 적치) 합과 들어 있는 품목. Inbound 의 완제품 창고 판이다.
    def load_bins
      rows = Inbound.bins_under("fg_store").pluck(:id, :code, :capacity_units)
      ids = rows.map(&:first)
      on_hand = Quant.where(location_id: ids).where("qty > 0").group(:location_id, :product_id).sum(:qty)
      planned = Task.where(kind: "putaway", status: %w[planned started], to_location_id: ids).group(:to_location_id, :product_id).sum(:qty)

      qty_by = on_hand.merge(planned) { |_, a, b| a + b }.group_by { |(loc, _), _| loc }
      rows.map do |id, code, capacity|
        mine = qty_by.fetch(id, [])
        Bin.new(code, capacity || Float::INFINITY, mine.sum { |_, qty| qty }, mine.map { |(_, product_id), _| product_id }.to_set)
      end
    end

    # ① 같은 품목이 있고 남은 용량이 수량 이상인 칸 중 코드 순 첫 칸 ② 빈 칸 중 코드 순 첫 칸 ③ 없으면 nil.
    def choose_bin(bins, product_id, qty)
      bins.find { |b| b.products.include?(product_id) && b.capacity - b.used >= qty } ||
        bins.find { |b| b.products.empty? && b.capacity >= qty }
    end
  end
end
