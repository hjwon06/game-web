module Ops
  # 작업 하나를 계획한다: 종류에 맞는 자원 중 가장 일찍 비는 자원에 붙이고 시작·예상 완료 시각을 정한다.
  # 재고는 여기서 움직이지 않는다. 움직임은 Ops::Tick 이 완료 순간 stock_move 1건으로 만든다.
  # from 이 물리 위치면 그 칸의 재고를 예약(Reservation, active)으로 잡는다. 꺼낼 칸을 고르는 쪽(Ops::Removal)이 가용에서 뺀다.
  # 예약은 작업이 done 이 되면 consumed, cancelled 가 되면 released 로 Task 가 닫는다.
  # 계획하는 트랜잭션 안에서 다시 확인한다: 가용(현재고 - active 예약)이 모자라면 InsufficientStock, 도착 칸에 자리가 없으면 CapacityExceeded.
  class Plan
    class NoResource < StandardError; end

    RESOURCE_KIND = {
      "unload" => "dock_in", "putaway" => "forklift", "pick" => "forklift", "feed" => "forklift",
      "inspect" => "worker", "load" => "dock_out", "count" => "worker"
    }.freeze
    BASE_SECONDS = { "unload" => 90, "putaway" => 45, "pick" => 40, "feed" => 35, "inspect" => 60, "load" => 120, "count" => 60 }.freeze
    OPEN = %w[planned started].freeze
    JITTER = (0.8..1.2)
    DEFAULT_SEED = 20261008

    class << self
      # 소요시간 난수. 시드를 고정해 두면 같은 호출 순서에서 같은 값이 나온다(테스트 재현).
      def rng = (@rng ||= Random.new(DEFAULT_SEED))
      def reseed!(seed = DEFAULT_SEED) = (@rng = Random.new(seed))

      def call(**args) = new(**args).call

      # 그 종류 자원 중 가장 빨리 비는 자원까지 남은 초(= next_free - now, 최소 0). kind 는 자원 종류("forklift") 또는 작업 종류("pick")다.
      # 읽기만 한다: 작업 스트림(planned_at·expected_finish_at)은 그대로이고, 진입 제한은 부르는 쪽이 이 값으로 건다.
      # now 는 부르는 쪽의 시뮬 시각이다(테스트·재생에서 벽시계와 다를 수 있다). 계획도 earliest_at=now 로 잡히므로 같은 기준이어야 한다.
      def queue_seconds(kind, now: Time.current)
        resource_kind = RESOURCE_KIND.fetch(kind.to_s, kind.to_s)
        ids = Resource.where(kind: resource_kind).pluck(:id)
        return 0 if ids.empty?

        free = new_free_map(ids, now)
        [free.values.min - now, 0].max.to_f
      end

      # 지게차 대기열이 FORKLIFT_ADMIT_SECONDS 이하일 때만 true. pick·putaway 계획이 새 작업을 만들기 전에 묻는다(feed 는 묻지 않는다).
      def forklift_admit?(now: Time.current)
        queue_seconds("forklift", now: now) <= Simulation::Config::FORKLIFT_ADMIT_SECONDS
      end

      private

      def new_free_map(ids, now)
        last = Task.where(resource_id: ids, status: OPEN).group(:resource_id).maximum(:expected_finish_at)
        ids.to_h { |id| [id, last[id] || now] }
      end
    end

    def initialize(kind:, product:, lot:, qty:, from:, to:, ref:, earliest_at:)
      @kind = kind.to_s
      @product = product
      @lot = lot
      @qty = qty
      @from = resolve_location(from)
      @to = resolve_location(to)
      @ref = ref
      @earliest_at = earliest_at
    end

    def call
      raise ArgumentError, "알 수 없는 kind: #{@kind}" unless RESOURCE_KIND.key?(@kind)

      Task.transaction do
        # 같은 종류 자원을 id 오름차순으로 잠가 동시 계획이 같은 next_free 를 보고 겹쳐 붙는 일을 막는다. Tick 과 같은 순서다.
        resources = Resource.where(kind: RESOURCE_KIND.fetch(@kind)).order(:id).lock.to_a
        raise NoResource, "#{RESOURCE_KIND.fetch(@kind)} 자원이 없다" if resources.empty?

        verify!

        now = Time.current
        free = next_free_by_resource(resources.map(&:id), now)
        resource = resources.min_by { |r| [free.fetch(r.id), r.id] }
        planned_at = [@earliest_at, free.fetch(resource.id)].max

        task = Task.create!(
          kind: @kind, status: "planned", resource: resource, product: @product, lot: @lot, qty: @qty,
          from_location: @from, to_location: @to, planned_at: planned_at,
          expected_finish_at: planned_at + duration_seconds,
          ref_type: @ref&.class&.name, ref_id: @ref&.id
        )
        reserve(task)
        task
      end
    end

    private

    # 계획하는 순간 한 번 더 확인한다. 호출자가 고른 뒤 다른 planner 가 같은 재고·같은 칸 자리를 가져갔을 수 있다.
    # 잠금 순서는 Inventory::Move 와 같다(도착 칸 위치 행 -> 재고 행). 반대로 잡으면 같은 칸을 두고 Tick 의 이동과 교착한다.
    # 실사(count)는 수량을 옮기지 않으므로 재고도 자리도 보지 않는다.
    def verify!
      return if @kind == "count"

      verify_capacity!
      verify_source!
    end

    # to 가 용량 있는 칸이면 그 위치 행을 잠그고 (현재고 + 그 칸으로 가는 열린 작업) + qty <= 용량 인지 본다.
    def verify_capacity!
      return unless @to.capacity_units

      capacity = Location.where(id: @to.id).lock("FOR NO KEY UPDATE").pick(:capacity_units) or return
      on_hand = BigDecimal(Quant.where(location_id: @to.id).sum(:qty).to_s)
      incoming = BigDecimal(Task.where(to_location_id: @to.id, status: OPEN).sum(:qty).to_s)
      return if on_hand + incoming + @qty <= capacity

      raise Inventory::CapacityExceeded,
            "#{@to.code} 자리 없음: 용량 #{capacity} / 현재고 #{on_hand.to_s('F')} + 들어오는 중 #{incoming.to_s('F')} / 요청 #{@qty.to_s}"
    end

    # from 이 물리 위치면 그 (품목, 로트, 위치) 재고 행을 잠그고 (현재고 - active 예약) >= qty 인지 본다. 가상 위치는 재고를 세지 않는다.
    def verify_source!
      return unless @from.physical?

      on_hand = Quant.where(product_id: @product.id, lot_id: @lot&.id, location_id: @from.id).lock.pluck(:qty).sum(BigDecimal("0"))
      held = BigDecimal(Reservation.active.where(product_id: @product.id, lot_id: @lot&.id, location_id: @from.id).sum(:qty).to_s)
      return if on_hand - held >= @qty

      raise Inventory::InsufficientStock,
            "#{@from.code} 가용 부족: 현재고 #{on_hand.to_s('F')} - 예약 #{held.to_s('F')} / 요청 #{@qty.to_s}"
    end

    # from 이 물리 위치면 그 칸의 재고(품목·로트·위치)를 작업 몫으로 잡는다. 작업과 같은 트랜잭션이라 둘 중 하나만 남는 일이 없다.
    # 가상 위치(supplier 등)는 재고를 세지 않으므로 잡지 않는다. 실사(count)는 수량을 옮기지 않으므로 잡지 않는다.
    def reserve(task)
      return unless @from.physical? && @kind != "count"

      Reservation.create!(task: task, product: @product, lot: @lot, location: @from, qty: @qty, status: "active")
    end

    def resolve_location(loc)
      loc.is_a?(Location) ? loc : Location.find_by!(code: loc.to_s)
    end

    # 자원별 마지막 planned/started 작업의 예상 완료. 일이 없으면 now.
    def next_free_by_resource(ids, now)
      last = Task.where(resource_id: ids, status: %w[planned started]).group(:resource_id).maximum(:expected_finish_at)
      ids.to_h { |id| [id, last[id] || now] }
    end

    # 밀리초 단위 Rational. Float 를 Time 에 더하면 마이크로초 아래 찌꺼기가 남아 DB 에서 읽은 값과 어긋난다.
    def duration_seconds
      Rational((BASE_SECONDS.fetch(@kind) * self.class.rng.rand(JITTER) * 1000).round, 1000)
    end
  end
end
