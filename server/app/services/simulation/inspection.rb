module Simulation
  # 검사: qc 에 쌓인 완제품을 작업지시별로 묶어 inspect 작업(작업자)을 계획하고, 검사가 끝나면 합격분의 적치(qc → fg 칸)를 계획한다.
  # Runner 가 10초마다 부른다. 재고는 여기서 움직이지 않는다 — Ops::Tick 이 inspect 완료 순간 불량분 qc_fail(qc → scrap) 1건을,
  # 적치 완료 순간 qc_pass(qc → fg 칸) 1건을 만든다.
  #
  # 검사 시점: 미검사 수량이 팔레트(PALLET_QTY) 이상이거나, 그 수량 중 가장 오래된 도착분이 INSPECT_MAX_WAIT_SECONDS 를 넘었을 때.
  # 1건 수량은 min(미검사량, PALLET_QTY)라 합격분 적치도 팔레트 단위다(더 쌓였으면 다음 호출에 이어서 계획한다).
  # 미검사 수량 = min(원장 기준(qc 로 들어온 produce 합 - inspections 원장 합 - 진행 중 검사), qc 현재고 - 이미 맡겨진 수량). 둘 중 작은 쪽이라
  # 작업 기록이 지워져도(Task.prune!) 미검사량이 변하지 않고, qc 재고보다 많이 검사하지도 않는다.
  # 상태 기반이라 같은 시각에 다시 불려도 작업이 늘지 않는다.
  class Inspection
    # 반환: { inspect:, putaway:, waiting: } (이번 호출에서 계획한 검사·적치 수, 칸이 없어 qc 에 남은 합격분 수)
    def self.call(now:, logger: Rails.logger) = new(now: now, logger: logger).call

    # 검사 작업이 done 이 된 같은 트랜잭션에서 Ops::Tick 이 부른다: 합격분 적치를 바로 계획해, 예약이 consumed 로 닫힌 뒤
    # 다른 작업이 끼어들기 전에 qc 합격분을 새 적치 예약으로 넘긴다. 칸이 없거나 계획이 안 되면 nil (주기 실행 plan_putaways 가 이어서 본다).
    def self.plan_putaway_for(task, now: Time.current, logger: Rails.logger)
      new(now: now, logger: logger).plan_putaway(task)
    end

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
      arrivals = arrivals_by_lot(qc, candidates.select { |_, _, pending| pending < Config::PALLET_QTY }.map { |q, _, _| q.lot_id })
      candidates.each do |quant, order, _|
        # 앞 로트가 방금 차감했으므로 pending 을 다시 계산한다.
        pending = [uninspected.fetch(order.id, 0), quant.qty - claimed.fetch(quant.lot_id, 0)].min
        next unless pending.positive? && due?(arrivals[quant.lot_id], pending)

        qty = [pending, Config::PALLET_QTY].min
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

    # { 작업지시 id => EPOCH 이후 qc 로 들어온 양 - 검사한 양 }
    # 검사한 양 = 원장(inspections: 검사 1행 = 이동 1건, qty 포함, EPOCH 이후) + 진행 중 검사 작업(planned/started) + 합격분이 아직 원장에 없는 최근 완료 검사.
    # 지워지는 tasks 가 아니라 inspections 로 센다(Task.prune! 으로 done 작업이 지워져도 미검사량이 늘지 않는다).
    # 합격 행은 적치(qc_pass)가 끝나야 생기므로, 검사는 끝났지만 합격분이 아직 qc 에 있는 동안만 완료 작업(최근 INSPECT_LOOKBACK_SECONDS)에서 메운다.
    # 이력(1단계): produce 이동은 작업 큐 이전부터 있어 두 합을 EPOCH 이후로 맞춘다(sim:rebase).
    def uninspected_by_order(qc, order_ids)
      epoch = Config.inventory_epoch&.utc
      moves = StockMove.where(move_type: "produce", ref_type: "WorkOrder", ref_id: order_ids, to_location_id: qc.id)
      moves = moves.where("(#{ARRIVED_AT_SQL}) >= ?", epoch.iso8601) if epoch
      produced = moves.group(:ref_id).sum(:qty)
      # ::Inspection — 이 클래스 안의 맨 이름 Inspection 은 Simulation::Inspection 자신이라 모델이 아니다.
      ledger = ::Inspection.where(work_order_id: order_ids)
      ledger = ledger.where(inspected_at: epoch..) if epoch
      inspected = ledger.group(:work_order_id).sum(:qty)
      open = Task.where(kind: "inspect", ref_type: "WorkOrder", ref_id: order_ids, status: %w[planned started])
      open = open.where(planned_at: epoch..) if epoch
      open.group(:ref_id).sum(:qty).each { |id, qty| inspected[id] = inspected.fetch(id, 0) + qty }
      passed_in_flight(order_ids, epoch).each { |id, qty| inspected[id] = inspected.fetch(id, 0) + qty }
      produced.to_h { |id, qty| [id, qty - inspected.fetch(id, 0)] }
    end

    # { 작업지시 id => 검사는 끝났지만 합격 이동(qc_pass)이 원장에 아직 없는 수량 }. 완료 검사의 합격분(검사량 - 불량 이동) - 끝난 적치의 합격 행.
    def passed_in_flight(order_ids, epoch)
      cutoff = @now - Config::INSPECT_LOOKBACK_SECONDS
      done = Task.where(kind: "inspect", ref_type: "WorkOrder", ref_id: order_ids, status: "done", planned_at: [cutoff - 600, epoch].compact.max..)
                 .where("finished_at > ?", cutoff).includes(:stock_move).to_a
      return {} if done.empty?

      moves = Task.where(kind: "putaway", ref_type: "Task", ref_id: done.map(&:id), status: "done").where.not(stock_move_id: nil)
                  .pluck(:ref_id, :stock_move_id)
      recorded = ::Inspection.where(stock_move_id: moves.map(&:last), result: "pass").pluck(:stock_move_id, :qty).to_h
      landed = moves.group_by(&:first).transform_values { |rows| rows.sum { |_, move_id| recorded.fetch(move_id, 0) } }
      done.each_with_object(Hash.new(0)) do |task, sums|
        left = task.qty - (task.stock_move&.qty || 0) - landed.fetch(task.id, 0)
        sums[task.ref_id] += left if left.positive?
      end
    end

    # arrivals: arrivals_by_lot 의 이 로트 몫(최근 도착 순 [수량, 도착 ISO]). 배치 수량 이상이면 도착 시각을 보지 않는다.
    def due?(arrivals, pending)
      pending >= Config::PALLET_QTY || oldest_arrival(arrivals, pending) <= @now - Config::INSPECT_MAX_WAIT_SECONDS
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

    SETTLED_REASON = "settled: qc 가용 재고 없음".freeze

    # 검사가 끝났는데 (취소되지 않은) 적치가 없는 작업마다 합격분(검사 수량 - 불량 이동)의 적치를 계획한다. 칸이 없으면 qc 에 두고 다음 호출에 다시 본다.
    # 적치 대상의 진실은 qc 실재고 - active 예약이다(로트별). 검사 기록 합이 그보다 크면 기록이 틀린 것이라, 오래된 검사부터
    # min(합격분 - 이미 계획된 적치, 남은 가용) 만 계획한다. 가용이 0 이면 Ops::Plan 을 부르지 않고 그 검사를 종결로 표시한다
    # (취소된 적치 1건에 SETTLED_REASON 을 달아 covered 로 본다 — 다음 호출부터 다시 보지 않는다). 경고 로그는 호출당 1줄.
    def plan_putaways
      waiting = waiting_inspections
      return if waiting.empty?

      @batch = true
      load_available(waiting)
      stuck = 0
      settled = 0
      deferred = 0
      waiting.each do |task|
        next unless (task.qty - (task.stock_move&.qty || 0)).positive?

        # 진입 제한: 지게차 대기열이 길면 새 적치를 만들지 않고 qc 에 둔 채 다음 호출로 미룬다(feed 가 먼저 지게차를 받게 한다).
        unless Ops::Plan.forklift_admit?(now: @now)
          deferred += 1
          next
        end

        case (result = try_putaway(task, planned: 0))
        when :no_stock
          settle!(task)
          settled += 1
        when :stuck then stuck += 1
        else @counts[:putaway] += 1 if result
        end
      end
      @counts[:waiting] = stuck
      if deferred.positive?
        @logger.info("sim inspection #{@now.iso8601} 지게차 대기 #{Ops::Plan.queue_seconds('forklift', now: @now).round}초 > #{Config::FORKLIFT_ADMIT_SECONDS}초라 적치 #{deferred}건 보류")
      end
      return unless stuck.positive? || settled.positive?

      @logger.warn("sim inspection #{@now.iso8601} 적치 보류: 칸 없음·계획 거부로 qc 에 #{stuck}건 대기, qc 가용 재고 없어 종결 #{settled}건")
    end

    public

    # 완료된 검사 task 의 합격분(검사 수량 - 불량 이동) 적치를 계획해 돌려준다. 합격분이 없거나 qc 가용이 없거나 칸이 없거나 계획이 거부되면 nil.
    # 적치량은 min(합격분 - 이미 계획된 적치, qc 가용(그 로트 현재고 - active 예약)).
    def plan_putaway(task)
      result = try_putaway(task)
      result.is_a?(Task) ? result : nil
    end

    private

    # Task(계획됨) | :no_stock(qc 가용 0 — Plan 을 부르지 않았다) | :stuck(칸 없음·계획 거부) | nil(적치할 합격분 없음)
    def try_putaway(task, planned: nil)
      pass_qty = task.qty - (task.stock_move&.qty || 0)
      return nil unless pass_qty.positive?

      planned ||= Task.where(kind: "putaway", ref_type: "Task", ref_id: task.id, status: %w[planned started done]).sum(:qty)
      need = pass_qty - planned
      return nil unless need.positive?

      key = [task.product_id, task.lot_id]
      load_available([task]) unless @avail&.key?(key)
      qty = [need, @avail.fetch(key)].min
      return :no_stock unless qty.positive?

      # 칸은 적치 규칙(Ops::Putaway)이 고른다. 방금 계획한 적치도 DB 에 있어 다음 건의 칸 계산에 들어간다.
      bin = Ops::Putaway.choose(product: task.product, qty: qty)
      return warn_once(task, "적치할 칸 없음") unless bin

      planned_task = ApplicationRecord.transaction(requires_new: true) do
        Ops::Plan.call(kind: "putaway", product: task.product, lot: task.lot, qty: qty, from: "qc", to: bin,
                       ref: task, earliest_at: task.finished_at || @now)
      end
      @avail[key] -= qty
      planned_task
    rescue Inventory::InsufficientStock, Inventory::CapacityExceeded, Ops::Plan::NoResource => e
      warn_once(task, "#{e.class.name.demodulize} #{e.message}")
    end

    # 배치(plan_putaways)는 끝에서 건수 합계 1줄을 남기므로 건별 로그를 내지 않는다. 단건 경로(Tick)는 호출당 1건이라 바로 남긴다.
    def warn_once(task, reason)
      @logger.warn("sim inspection putaway 계획 보류 task=#{task.id}: #{reason}") unless @batch
      :stuck
    end

    # { [품목 id, 로트 id] => qc 현재고 - active 예약 } 를 @avail 에 채운다. 쿼리 2회(재고, 예약) — 검사 건수와 무관하다.
    def load_available(tasks)
      @avail ||= {}
      @qc ||= Location.find_by!(code: "qc")
      pairs = tasks.map { |t| [t.product_id, t.lot_id] }.uniq - @avail.keys
      return if pairs.empty?

      product_ids = pairs.map(&:first).uniq
      lot_ids = pairs.map(&:last).uniq
      on_hand = Quant.where(location_id: @qc.id, product_id: product_ids, lot_id: lot_ids).group(:product_id, :lot_id).sum(:qty)
      held = Reservation.active.where(location_id: @qc.id, product_id: product_ids, lot_id: lot_ids).group(:product_id, :lot_id).sum(:qty)
      pairs.each { |key| @avail[key] = [on_hand.fetch(key, 0) - held.fetch(key, 0), 0].max }
    end

    # 종결 표시: 취소된 적치 1건(ref = 검사 task). waiting_inspections 가 covered 로 본다. 재고는 움직이지 않고 예약도 없다.
    def settle!(task)
      Task.create!(kind: "putaway", status: "cancelled", product: task.product, lot: task.lot,
                   qty: task.qty - (task.stock_move&.qty || 0), from_location: @qc, to_location: Location.find_by!(code: "fg_store"),
                   planned_at: @now, finished_at: @now, cancel_reason: SETTLED_REASON, ref_type: "Task", ref_id: task.id)
    end

    def waiting_inspections
      cutoff = @now - Config::INSPECT_LOOKBACK_SECONDS
      # planned_at 조건은 (status, planned_at) 인덱스 범위로 읽기 위한 것이다.
      done = Task.where(kind: "inspect", status: "done", planned_at: (cutoff - 600)..)
                 .where("finished_at > ?", cutoff).includes(:product, :lot, :stock_move).order(:finished_at, :id).to_a
      return [] if done.empty?

      children = Task.where(kind: "putaway", ref_type: "Task", ref_id: done.map(&:id)).pluck(:ref_id, :status, :cancel_reason)
      cancelled, live = children.partition { |_, status, _| status == "cancelled" }
      settled, cancelled = cancelled.partition { |_, _, reason| reason == SETTLED_REASON }
      covered = (live + settled).map(&:first).to_set
      cancels = cancelled.map(&:first).tally
      done.reject { |t| covered.include?(t.id) || cancels.fetch(t.id, 0) >= Config::MAX_PUTAWAY_CANCELS }
    end
  end
end
