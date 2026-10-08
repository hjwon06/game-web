module Inventory
  # 모든 재고 변동의 유일한 쓰기 경로. 한 트랜잭션에서 원장(stock_moves)과 현재고(quants)를 같이 바꾼다.
  # 잠금 순서는 항상 location_id 오름차순이라 A→B 와 B→A 가 동시에 와도 교착하지 않는다.
  class Move
    class InvalidPath < StandardError; end

    # move_type => [from 위치 code, to 위치 code]. 10번째 유형 추가 금지(StockMove::MOVE_TYPES 도 9개 동결).
    # 경로는 위치의 구역 code 로 가른다(Location#zone_code): 자기 자신이나 조상 중 raw_store/line_side/fg_store/receiving/qc/shipping,
    # 가상 위치는 자기 code. 그래서 raw_store 아래 칸(bin)도 raw_store 로 취급한다. kind 는 구역 루트(Location::DEFAULTS)의 kind 와 같아야 한다.
    # raw 칸 → production 직접 issue 는 없다: raw 칸 → (feed) → line_side → (issue) → production.
    ALLOWED_PATHS = {
      "receive" => %w[supplier receiving],
      "putaway" => %w[receiving raw_store],
      "feed"    => %w[raw_store line_side],
      "issue"   => %w[line_side production],
      "produce" => %w[production qc],
      "qc_pass" => %w[qc fg_store],
      "qc_fail" => %w[qc scrap],
      "pick"    => %w[fg_store shipping],
      "ship"    => %w[shipping customer],
      "adjust"  => %w[inventory_loss raw_store]
    }.freeze
    # adjust(순환 실사 조정)만 경로가 여럿이다: 가상 위치 inventory_loss <-> raw_store·fg_store 칸, 양방향(부족분은 칸 -> inventory_loss, 초과분은 반대).
    EXTRA_PATHS = {
      "adjust" => [%w[raw_store inventory_loss], %w[inventory_loss fg_store], %w[fg_store inventory_loss]]
    }.freeze
    KIND_BY_CODE = Location::DEFAULTS.to_h { |code, _name, kind, _role| [code, kind] }.freeze

    # 같은 멱등키로 이미 있는 이동이 이번 요청과 같은 내용인지 본다. 다르면 IdempotencyConflict.
    def self.ensure_same!(existing, product_id:, lot_id:, from_id:, to_id:, qty:, move_type:, ref_type:, ref_id:)
      actual = { product_id: existing.product_id, lot_id: existing.lot_id, from_id: existing.from_location_id,
                 to_id: existing.to_location_id, qty: existing.qty, move_type: existing.move_type,
                 ref_type: existing.ref_type, ref_id: existing.ref_id }
      expected = { product_id: product_id, lot_id: lot_id, from_id: from_id, to_id: to_id, qty: qty,
                   move_type: move_type, ref_type: ref_type, ref_id: ref_id }
      diff = expected.keys.reject { |k| actual[k] == expected[k] }
      return existing if diff.empty?

      raise IdempotencyConflict, "멱등키 #{existing.idempotency_key} 는 다른 내용으로 이미 쓰였다: #{diff.join(', ')}"
    end

    def self.call(**args) = new(**args).call

    # occurred_at 를 안 주면 DB 기본값(now())이다. 시뮬레이터가 "그 분"의 이동을 만들 때만 준다.
    def initialize(product:, lot:, from:, to:, qty:, move_type:, ref:, idempotency_key:, occurred_at: nil)
      @occurred_at = occurred_at
      @product = product
      @lot = lot
      @from = resolve_location(from)
      @to = resolve_location(to)
      @qty = BigDecimal(qty.to_s)
      @move_type = move_type.to_s
      @ref = ref
      @key = idempotency_key.to_s
    end

    def call
      validate!
      existing = StockMove.find_by(idempotency_key: @key)
      return same_as_request!(existing) if existing

      # savepoint 로 감싼다. 바깥 트랜잭션(Backflush 등) 안에서 유니크 위반이 나도 바깥은 살아 있다.
      StockMove.transaction(requires_new: true) do
        # 용량 있는 칸은 같은 칸으로 들어오는 이동끼리 직렬화한다. 품목이 다르면 quants 행이 달라 행 잠금만으로는 합계를 지킬 수 없다.
        # FOR NO KEY UPDATE 는 FK 검사(KEY SHARE)와 충돌하지 않는다. 한 이동이 잡는 위치 잠금은 도착지 하나라 교착 고리가 없다.
        capacity = lock_capacity
        quants = lock_quants
        # 잠금을 잡은 뒤 다시 본다. 같은 키가 동시에 오면 뒤 요청은 여기서 앞 요청의 결과를 본다.
        existing = StockMove.find_by(idempotency_key: @key)
        next same_as_request!(existing) if existing

        from_quant = quants.fetch(@from.id)
        reject_insufficient!(from_quant) if @from.physical? && from_quant.qty < @qty
        check_capacity!(capacity) if capacity

        attrs = { product: @product, lot: @lot, from_location: @from, to_location: @to, qty: @qty,
                  move_type: @move_type, ref_type: @ref&.class&.name, ref_id: @ref&.id, idempotency_key: @key }
        attrs[:occurred_at] = @occurred_at if @occurred_at
        move = StockMove.create!(**attrs)
        Quant.where(id: from_quant.id).update_all(["qty = qty - ?, updated_at = now()", @qty])
        Quant.where(id: quants.fetch(@to.id).id).update_all(["qty = qty + ?, updated_at = now()", @qty])
        move
      end
    rescue ActiveRecord::RecordNotUnique
      same_as_request!(StockMove.find_by!(idempotency_key: @key))
    end

    private

    def same_as_request!(existing)
      self.class.ensure_same!(existing, product_id: @product.id, lot_id: @lot&.id, from_id: @from.id, to_id: @to.id,
                                        qty: @qty, move_type: @move_type, ref_type: @ref&.class&.name, ref_id: @ref&.id)
    end

    def resolve_location(loc)
      loc.is_a?(Location) ? loc : Location.find_by!(code: loc.to_s)
    end

    def validate!
      raise ArgumentError, "idempotency_key 가 필요하다" if @key.empty?
      raise ArgumentError, "qty 는 0보다 커야 한다: #{@qty}" unless @qty.positive?

      path = ALLOWED_PATHS[@move_type] or raise InvalidPath, "알 수 없는 move_type: #{@move_type}"
      paths = [path] + EXTRA_PATHS.fetch(@move_type, [])
      from_zone = @from.zone_code
      to_zone = @to.zone_code
      kinds_ok = [[from_zone, @from], [to_zone, @to]].all? { |zone, loc| KIND_BY_CODE[zone] == loc.kind }
      unless paths.include?([from_zone, to_zone]) && kinds_ok
        raise InvalidPath, "#{@move_type} 는 #{paths.map { |p| p.join('→') }.join(', ')} 만 허용한다 " \
                           "(요청: #{@from.code}[#{from_zone}](#{@from.kind})→#{@to.code}[#{to_zone}](#{@to.kind}))"
      end

      if @lot && @lot.product_id != @product.id
        raise ArgumentError, "lot #{@lot.id} 은 product #{@product.id} 의 로트가 아니다"
      end
    end

    # 두 행을 location_id 오름차순으로 만들고(없으면 ON CONFLICT DO NOTHING) FOR UPDATE 로 잠근다.
    # 물리 위치 마이너스는 DB 트리거(quants_physical_non_negative)가 막는다.
    def lock_quants
      locations = [@from, @to].sort_by(&:id)
      locations.each do |loc|
        Quant.connection.execute(Quant.sanitize_sql_array([<<~SQL.squish, @product.id, @lot&.id, loc.id]))
          INSERT INTO quants (product_id, lot_id, location_id, qty, created_at, updated_at)
          VALUES (?, ?, ?, 0, now(), now())
          ON CONFLICT (product_id, COALESCE(lot_id, 0::bigint), location_id) DO NOTHING
        SQL
      end
      Quant.where(product_id: @product.id, lot_id: @lot&.id, location_id: locations.map(&:id))
           .order(:location_id).lock.to_a.index_by(&:location_id)
    end

    # 도착지가 용량을 가질 때만 위치 행을 잠그고 잠근 뒤의 값을 돌려준다(없으면 nil). 잠금 뒤에 다시 읽어 용량 변경도 반영한다.
    def lock_capacity
      return nil unless @to.capacity_units

      Location.where(id: @to.id).lock("FOR NO KEY UPDATE").pick(:capacity_units)
    end

    # 칸 안의 모든 품목·로트 현재고 합(단위 무관 qty 합) + 이번 수량이 용량을 넘으면 거부.
    def check_capacity!(capacity)
      on_hand = Quant.where(location_id: @to.id).sum(:qty)
      return if on_hand + @qty <= capacity

      Rails.logger.warn({
        event: "inventory.move.rejected", reason: "capacity_exceeded", move_type: @move_type,
        product_id: @product.id, lot_id: @lot&.id, from: @from.code, to: @to.code,
        requested: @qty.to_s("F"), on_hand: on_hand.to_s("F"), capacity: capacity, idempotency_key: @key
      }.to_json)
      raise CapacityExceeded, "#{@to.code} 용량 초과: 용량 #{capacity} / 보유 #{on_hand.to_s('F')} / 요청 #{@qty.to_s('F')}"
    end

    def reject_insufficient!(from_quant)
      Rails.logger.warn({
        event: "inventory.move.rejected", reason: "insufficient_stock", move_type: @move_type,
        product_id: @product.id, lot_id: @lot&.id, from: @from.code, to: @to.code,
        requested: @qty.to_s("F"), on_hand: from_quant.qty.to_s("F"), idempotency_key: @key
      }.to_json)
      raise InsufficientStock, "#{@from.code} 재고 부족: 요청 #{@qty.to_s('F')} / 보유 #{from_quant.qty.to_s('F')}"
    end
  end
end
