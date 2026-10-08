module Simulation
  # 60초 경계마다 Runner 가 Flusher 다음에 부른다. 생산 → 자재 소비(백플러시), 신규 수주.
  # 입고(트럭·하차·적치)는 Simulation::Inbound, 라인 공급은 LineFeed, 검사는 Inspection, 출하는 Shipping 이 작업으로 계획하고
  # Ops::Tick 이 완료 순간 이동을 만든다. 여기서는 line_side 에 공급된 재고를 꺼내 쓰기만 한다.
  # 재고는 전부 Inventory::* 를 거친다. 여기서 production_events·work_orders 는 읽기만 한다.
  # 같은 분에 다시 불려도 이동이 늘지 않는다(produce 키는 (작업지시, 분), issue 키는 거기에 (자재, line_side, 로트)가 붙는다).
  class Logistics
    # 반환: { backflush:, skipped:, order: } (이번 호출에서 실제로 한 일)
    def self.call(now:, logger: Rails.logger) = new(now: now, logger: logger).call

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
      step("backflush") { catch_up(epoch) }
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

    # 작업지시별 good(EPOCH 이후 production_events) - done(produce 이동) 이 양수면 그만큼 Backflush.
    # 자재가 모자란 작업지시는 이번 분을 건너뛴다(skipped). 자재는 LineFeed 가 raw 칸에서 line_side 로 따로 채운다.
    # 이번 분 produce 키가 이미 있는 작업지시는 건드리지 않는다(남은 양은 다음 분 키로 처리된다).
    def catch_up(epoch)
      good = ProductionEvent.where(bucket_start: epoch...@minute).group(:work_order_id).sum(:good_qty)
      done = StockMove.where(move_type: "produce", ref_type: "WorkOrder", ref_id: good.keys).group(:ref_id).sum(:qty)
      orders = WorkOrder.where(id: good.keys).includes(:item).index_by(&:id)
      keys = good.keys.index_with { |id| "produce:#{id}:#{@iso}" }
      minted = StockMove.where(idempotency_key: keys.values).pluck(:idempotency_key).to_set

      good.sort.each do |order_id, good_qty|
        next if minted.include?(keys.fetch(order_id))

        delta = good_qty.to_i - done.fetch(order_id, 0).to_i
        next unless delta.positive?

        backflush(orders.fetch(order_id), delta)
      end
    end

    def backflush(order, delta)
      savepoint { consume_and_produce(order, delta) }
      @counts[:backflush] += 1
    rescue Inventory::InsufficientStock
      @counts[:skipped] += 1
    rescue StandardError => e # 한 작업지시 때문에 나머지를 막지 않는다
      @logger.error("sim logistics backflush #{order.code} #{@iso}: #{e.class} #{e.message}")
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
                           ref: order, idempotency_key: "produce:#{order.id}:#{@iso}")
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
