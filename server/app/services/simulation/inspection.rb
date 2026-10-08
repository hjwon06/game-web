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
      # 로트마다 (이 작업지시의 미검사 수량, 로트 몫) 의 작은 쪽. 계획한 만큼은 작업지시의 미검사에서 바로 빼서 다음 로트가 같은 수량을 또 잡지 않게 한다.
      candidates = stock.filter_map do |quant|
        order = orders.fetch(quant.lot.lot_no)
        pending = [uninspected.fetch(order.id, 0), quant.qty - claimed.fetch(quant.lot_id, 0)].min
        [quant, order, pending] if pending.positive?
      end
      arrivals = arrivals_by_lot(qc, candidates.select { |_, _, pending| pending < Config::INSPECT_BATCH_QTY }.map { |q, _, _| q.lot_id })
      candidates.each do |quant, order, _|
        # 앞 로트가 방금 차감했으므로 pending 을 다시 계산한다.
        pending = [uninspected.fetch(order.id, 0), quant.qty - claimed.fetch(quant.lot_id, 0)].min
        next unless pending.positive? && due?(arrivals[quant.lot_id], pending)

        qty = [pending, Location::BIN_CAPACITY].min
        Ops::Plan.call(kind: "inspect", product: order.item, lot: quant.lot, qty: qty,
                       from: qc, to: "fg_store", ref: order, earliest_at: @now)
        uninspected[order.id] -= qty
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

    # arrivals: arrivals_by_lot 의 이 로트 몫(최근 도착 순 [수량, 도착 ISO]). 배치 수량 이상이면 도착 시각을 보지 않는다.
    def due?(arrivals, pending)
      pending >= Config::INSPECT_BATCH_QTY || oldest_arrival(arrivals, pending) <= @now - Config::INSPECT_WAIT_SECONDS
    end

    ARRIVALS_PER_LOT = 200

    # { lot_id => [[qty, 도착 ISO], ...] } 최근 도착 순, 로트마다 ARRIVALS_PER_LOT 건까지. 로트 수와 상관없이 쿼리 1회.
    def arrivals_by_lot(qc, lot_ids)
      return {} if lot_ids.empty?

      ranked = StockMove.where(move_type: "produce", to_location_id: qc.id, lot_id: lot_ids)
                        .select("stock_moves.id, stock_moves.lot_id, stock_moves.qty, (#{ARRIVED_AT_SQL}) AS arrived_at, " \
                                "ROW_NUMBER() OVER (PARTITION BY stock_moves.lot_id ORDER BY stock_moves.id DESC) AS rn")
      StockMove.from(ranked, :stock_moves).where("rn <= ?", ARRIVALS_PER_LOT).order(:lot_id, id: :desc)
               .pluck(:lot_id, :qty, Arel.sql("arrived_at")).group_by(&:first).transform_values { |rows| rows.map { |_, qty, at| [qty, at] } }
    end

    # 미검사 수량(= 가장 최근에 도착한 pending 만큼)에서 가장 오래된 도착분의 시각. 먼저 도착한 것부터 검사됐다고 본다.
    def oldest_arrival(rows, pending)
      rows ||= []
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

      stuck = 0
      waiting.each do |task|
        pass_qty = task.qty - (task.stock_move&.qty || 0)
        next unless pass_qty.positive?

        # 칸은 적치 규칙(Ops::Putaway)이 고른다. 방금 계획한 적치도 DB 에 있어 다음 건의 칸 계산에 들어간다.
        bin = Ops::Putaway.choose(product: task.product, qty: pass_qty)
        unless bin
          stuck += 1
          next
        end

        Ops::Plan.call(kind: "putaway", product: task.product, lot: task.lot, qty: pass_qty, from: "qc", to: bin,
                       ref: task, earliest_at: task.finished_at)
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

  end
end
