module Simulation
  # 60초 경계마다 Runner 가 Flusher 다음에 부른다. 생산 → 자재 소비(백플러시), 신규 수주.
  # 입고(트럭·하차·적치)는 Simulation::Inbound, 라인 공급은 LineFeed, 검사는 Inspection, 출하는 Shipping 이 작업으로 계획하고
  # Ops::Tick 이 완료 순간 이동을 만든다. 여기서는 line_side 에 공급된 재고를 꺼내 쓰기만 한다.
  # 재고는 전부 Inventory::* 를 거친다. 여기서 production_events·work_orders 는 읽기만 한다.
  # 같은 분에 다시 불려도 이동이 늘지 않는다(produce 키는 (작업지시, 분), issue 키는 거기에 (자재, line_side, 로트)가 붙는다).
  class Logistics
    # 반환: { backflush:, skipped:, order: } (이번 호출에서 실제로 한 일)
    def self.call(now:, logger: Rails.logger) = new(now: now, logger: logger).call

    # 프로세스 메모리 상태: discarded[작업지시] = 상한을 넘어 버린 수량, starved[작업지시] = { minutes:, at: } 연속 부족 분.
    def self.state = (@state ||= { discarded: Hash.new(0), starved: {} })

    def self.reset_state! = @state = nil

    def initialize(now:, logger:)
      @minute = now.utc.beginning_of_minute
      @iso = @minute.iso8601
      @logger = logger
      @counts = { backflush: 0, skipped: 0, order: 0 }
    end

    def call
      epoch = Config.inventory_epoch&.utc # TimeWithZone/로컬 시각이 와도 UTC 로 맞춰 비교한다
      return @counts unless epoch

      # 모든 단계는 자기 트랜잭션(savepoint)에 감싸 한 단계의 실패(PG 오류 포함)가 뒤 단계를 막지 않게 한다.
      # 같은 분·같은 대상의 멱등키가 이미 있으면 그 단계는 이번 분에 아무것도 하지 않는다(재계산 금지).
      reset_state_for(epoch)
      step("backflush") { catch_up(epoch) }
      step("material short") { update_material_short }
      step("order") { new_order }
      @logger.info("sim logistics #{@iso} #{@counts.map { |k, v| "#{k}=#{v}" }.join(' ')}")
      @counts
    end

    private

    def savepoint(&) = ApplicationRecord.transaction(requires_new: true, &)

    # 실패하면 이 단계가 올린 카운트도 롤백과 함께 되돌린다.
    def step(name)
      snapshot = @counts.dup
      savepoint { yield }
    rescue StandardError => e
      @counts.replace(snapshot)
      @logger.error("sim logistics #{name} #{@iso}: #{e.class} #{e.message}")
    end

    # rake sim:rebase 로 epoch 가 바뀌면 이전 epoch 의 버린 양·부족 분 수는 의미가 없다(남기면 새 pending 에서 또 빼게 된다).
    def reset_state_for(epoch)
      state = self.class.state
      return if state[:epoch] == epoch

      state[:discarded] = Hash.new(0)
      state[:starved] = {}
      state[:epoch] = epoch
    end

    # 작업지시별 pending = good(EPOCH 이후 production_events) - done(EPOCH 이후 produce 이동) - 버린 양 이 양수면 Backflush.
    # good 과 done 이 같은 구간(EPOCH 이후)이라야 rebase 직후 pending 이 0 이다. done 은 이동의 occurred_at(= 그 분)으로 가른다.
    # 한 분에 처리하는 양(chunk)은 min(pending, 자재별 floor(line_side 재고 / qty_per) 의 최솟값, BACKFLUSH_CHUNK_MAX) 이다.
    # 0 이면 그 작업지시만 이번 분을 건너뛰고(skipped) 다른 작업지시는 진행한다. 남은 pending 은 다음 분에 이어서 처리한다.
    # 자재는 LineFeed 가 raw 칸에서 line_side 로 따로 채운다.
    # 이번 분 produce 키가 이미 있는 작업지시는 건드리지 않는다(남은 양은 다음 분 키로 처리된다).
    def catch_up(epoch)
      good = ProductionEvent.where(bucket_start: epoch...@minute).group(:work_order_id).sum(:good_qty)
      done = StockMove.where(move_type: "produce", ref_type: "WorkOrder", ref_id: good.keys, occurred_at: epoch..)
                      .group(:ref_id).sum(:qty)
      orders = WorkOrder.where(id: good.keys).includes(:item).index_by(&:id)
      keys = good.keys.index_with { |id| "produce:#{id}:#{@iso}" }
      minted = StockMove.where(idempotency_key: keys.values).pluck(:idempotency_key).to_set

      good.sort.each do |order_id, good_qty|
        next if minted.include?(keys.fetch(order_id))

        order = orders.fetch(order_id)
        pending = cap_backlog(order, good_qty.to_i - done.fetch(order_id, 0).to_i - self.class.state[:discarded][order_id])
        if pending.positive?
          backflush(order, pending)
        else
          self.class.state[:starved].delete(order_id)
        end
      end
    end

    # pending 이 BACKLOG_CAP 을 넘으면 넘는 만큼은 EPOCH 를 앞당긴 것처럼 버리고(소급하지 않는다) 로그 1줄.
    # 버린 양은 프로세스 메모리에 둔다(bin/sim 단일 프로세스 전제). 재시작하면 pending 이 다시 계산돼 같은 규칙으로 또 잘린다.
    def cap_backlog(order, pending)
      excess = pending - Config::BACKLOG_CAP
      return pending unless excess.positive?

      self.class.state[:discarded][order.id] += excess
      @logger.info("sim logistics #{@iso} #{order.code} 미소비 #{pending}개가 상한 #{Config::BACKLOG_CAP}개를 넘어 #{excess}개를 소급하지 않고 버림")
      Config::BACKLOG_CAP
    end

    def backflush(order, pending)
      bom = BomLine.where(product_id: order.item.id).where("qty_per > 0").order(:component_id).includes(:component).to_a
      on_hand = line_side_on_hand(bom)
      limits = bom.to_h { |line| [line, (on_hand.fetch(line.component_id, 0) / line.qty_per).floor] }
      scarcest, can_make = limits.min_by { |_, count| count }
      chunk = [pending, Config::BACKFLUSH_CHUNK_MAX, can_make || pending].min
      return starve(order, pending, scarcest, on_hand) unless chunk.positive?

      savepoint { consume_and_produce(order, chunk) }
      self.class.state[:starved].delete(order.id)
      @counts[:backflush] += 1
    rescue Inventory::InsufficientStock
      @counts[:skipped] += 1
    rescue StandardError => e # 한 작업지시 때문에 나머지를 막지 않는다
      @logger.error("sim logistics backflush #{order.code} #{@iso}: #{e.class} #{e.message}")
    end

    def line_side_on_hand(bom)
      line_side = Location.find_by!(code: "line_side")
      Quant.where(location_id: line_side.id, product_id: bom.map(&:component_id)).group(:product_id).sum(:qty)
    end

    # 자재 부족으로 건너뜀. 작업지시별 연속 분 수를 세고(같은 분 재호출은 다시 세지 않는다), 10분 이상이면 10분마다 무엇이 부족한지 로그 1줄.
    def starve(order, pending, line, on_hand)
      @counts[:skipped] += 1
      entry = self.class.state[:starved][order.id] ||= { minutes: 0, at: nil }
      return if entry[:at] == @minute

      entry[:minutes] += 1
      entry[:at] = @minute
      return unless entry[:minutes] >= Config::STARVE_LOG_MINUTES && (entry[:minutes] % Config::STARVE_LOG_MINUTES).zero?

      @logger.warn("sim logistics #{@iso} #{order.code} 자재 부족 연속 #{entry[:minutes]}분: #{line.component.sku} " \
                   "line_side #{BigDecimal(on_hand.fetch(line.component_id, 0).to_s).to_s('F')} / 1개당 #{line.qty_per.to_s('F')} (미소비 #{pending}개)")
    end

    # 자재 대기 판단(매분). running 기계의 active 작업지시가 다음 60초에 만들 양(rate x 60 x qty_per, 자재별)을
    # line_side 가 하나라도 못 대면 material_short_since 를 채우고(이미 있으면 유지), 다 대면 nil 로 되돌린다. 바뀔 때만 로그 1줄.
    # 기계 state·version 은 건드리지 않는다(update_columns): version 이 바뀌면 누적기가 그 구간을 버리고, state 는 사용자 명령 대상이다.
    # Runner 의 snapshot 이 이 값을 읽어 자재 대기 기계에는 생산을 쌓지 않는다.
    def update_material_short
      Machine.where.not(state: "running").where.not(material_short_since: nil).update_all(material_short_since: nil)
      machines = Machine.where(state: "running").order(:id).to_a
      return if machines.empty?

      orders = WorkOrder.where(status: "active", machine_id: machines.map(&:id)).group_by(&:machine_id)
      boms = BomLine.where("qty_per > 0").includes(:component).group_by(&:product_id)
      on_hand = Quant.where(location_id: Location.find_by!(code: "line_side").id).group(:product_id).sum(:qty)

      machines.each do |machine|
        lacking = lacking_bom(machine, orders.fetch(machine.id, []), boms, on_hand)
        if lacking
          next if machine.material_short_since

          machine.update_columns(material_short_since: @minute)
          @logger.info("sim logistics #{@iso} #{machine.code} 자재 대기 시작: #{lacking[:line].component.sku} line_side " \
                       "#{BigDecimal(lacking[:have].to_s).to_s('F')} / 다음 #{Config::MATERIAL_SHORT_CHECK_SECONDS}초 필요 #{lacking[:need].round(1)}")
        elsif machine.material_short_since
          minutes = ((@minute - machine.material_short_since) / 60).floor
          machine.update_columns(material_short_since: nil)
          @logger.info("sim logistics #{@iso} #{machine.code} 자재 대기 해제 (#{minutes}분)")
        end
      end
    end

    # 이 기계가 다음 구간에 못 대는 자재 [{ line:, have:, need: }]. 다 대면 nil.
    def lacking_bom(machine, orders, boms, on_hand)
      produce = Config.rate(machine.code) * Config::MATERIAL_SHORT_CHECK_SECONDS
      orders.each do |order|
        boms.fetch(order.product_id, []).each do |line|
          have = on_hand.fetch(line.component_id, 0)
          need = produce * line.qty_per
          return { line: line, have: have, need: need } if have < need
        end
      end
      nil
    end

    # Inventory::Backflush 는 로트 없는 재고만 쓴다. 같은 일을 여기서 로트 단위로 한다:
    # BOM 자재를 line_side 에서 나눠 issue 하고(로트 없는 재고 → 오래된 로트 순) 완제품 produce 1건을 만든다.
    # 전체가 한 savepoint 라 자재가 하나라도 모자라면 InsufficientStock 과 함께 전부 되돌아간다.
    def consume_and_produce(order, delta)
      product = order.item
      BomLine.where(product_id: product.id).order(:component_id).includes(:component).each do |bom|
        issue_from_line_side(order, bom.component, bom.qty_per * delta)
      end
      Inventory::Move.call(product: product, lot: work_order_lot(product, order), from: "production",
                           to: Location.find_by!(code: "qc"), qty: delta, move_type: "produce",
                           ref: order, idempotency_key: "produce:#{order.id}:#{@iso}", occurred_at: @minute)
    end

    # line_side 의 재고를 로트 없는 것 → 로트가 오래된 순으로 쓴다. 모자라면 InsufficientStock(부족분은 line_side 에 공급돼야 풀린다).
    def issue_from_line_side(order, component, need)
      line_side = Location.find_by!(code: "line_side")
      quants = Quant.where(product_id: component.id, location_id: line_side.id).where("qty > 0").includes(:lot).to_a
                    .sort_by { |q| [q.lot&.created_at || Time.at(0), q.lot_id || 0] }
      production = Location.find_by!(code: "production")
      remaining = BigDecimal(need.to_s)
      quants.each do |quant|
        break unless remaining.positive?

        take = [quant.qty, remaining].min
        Inventory::Move.call(product: component, lot: quant.lot, from: line_side, to: production,
                             qty: take, move_type: "issue", ref: order,
                             idempotency_key: "issue:#{order.id}:#{component.id}:#{line_side.id}:#{quant.lot_id || 0}:#{@iso}")
        remaining -= take
      end
      return unless remaining.positive?

      raise Inventory::InsufficientStock, "#{component.sku} 재고 부족: 필요 #{BigDecimal(need.to_s).to_s('F')} / 부족 #{remaining.to_s('F')}"
    end

    # 완제품 로트는 작업지시 코드 하나당 하나다(Simulation::Inspection 이 이 로트를 받아 검사한다).
    def work_order_lot(product, order)
      Lot.transaction(requires_new: true) { Lot.find_or_create_by!(product_id: product.id, lot_no: order.code) }
    rescue ActiveRecord::RecordNotUnique
      Lot.find_by!(product_id: product.id, lot_no: order.code)
    end

    # --- 신규 수주 -----------------------------------------------------------------------------

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

    # 같은 연월 접두사(SO-YYMM-)의 마지막 번호 + 1. 잠금이 없다: Logistics 는 bin/sim 단일 프로세스에서만 돈다는 전제.
    def next_so_no
      prefix = "SO-#{@minute.strftime('%y%m')}-"
      last = SalesOrder.where("so_no LIKE ?", "#{prefix}%").pluck(:so_no)
                       .filter_map { |n| n.delete_prefix(prefix)[/\A\d+\z/]&.to_i }.max || 0
      format("%s%03d", prefix, last + 1)
    end
  end
end
