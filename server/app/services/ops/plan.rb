module Ops
  # 작업 하나를 계획한다: 종류에 맞는 자원 중 가장 일찍 비는 자원에 붙이고 시작·예상 완료 시각을 정한다.
  # 재고는 여기서 움직이지 않는다. 움직임은 Ops::Tick 이 완료 순간 stock_move 1건으로 만든다.
  class Plan
    class NoResource < StandardError; end

    RESOURCE_KIND = {
      "unload" => "dock_in", "putaway" => "forklift", "pick" => "forklift", "feed" => "forklift",
      "inspect" => "worker", "load" => "dock_out"
    }.freeze
    BASE_SECONDS = { "unload" => 90, "putaway" => 45, "pick" => 40, "feed" => 35, "inspect" => 60, "load" => 120 }.freeze
    JITTER = (0.8..1.2)
    DEFAULT_SEED = 20261008

    class << self
      # 소요시간 난수. 시드를 고정해 두면 같은 호출 순서에서 같은 값이 나온다(테스트 재현).
      def rng = (@rng ||= Random.new(DEFAULT_SEED))
      def reseed!(seed = DEFAULT_SEED) = (@rng = Random.new(seed))

      def call(**args) = new(**args).call
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

        now = Time.current
        free = next_free_by_resource(resources.map(&:id), now)
        resource = resources.min_by { |r| [free.fetch(r.id), r.id] }
        planned_at = [@earliest_at, free.fetch(resource.id)].max

        Task.create!(
          kind: @kind, status: "planned", resource: resource, product: @product, lot: @lot, qty: @qty,
          from_location: @from, to_location: @to, planned_at: planned_at,
          expected_finish_at: planned_at + duration_seconds,
          ref_type: @ref&.class&.name, ref_id: @ref&.id
        )
      end
    end

    private

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
