module Inventory
  # 모든 재고 변동의 유일한 쓰기 경로. 한 트랜잭션에서 원장(stock_moves)과 현재고(quants)를 같이 바꾼다.
  # 잠금 순서는 항상 location_id 오름차순이라 A→B 와 B→A 가 동시에 와도 교착하지 않는다.
  class Move
    class InvalidPath < StandardError; end

    # move_type => [from 위치 code, to 위치 code]. 8번째 유형 추가 금지(StockMove::MOVE_TYPES 도 7개 동결).
    # 위치는 고정 9개다(Location::DEFAULTS). 경로는 code 로 가르고, kind 도 그 9개의 kind 와 같아야 한다.
    ALLOWED_PATHS = {
      "receive" => %w[supplier receiving],
      "putaway" => %w[receiving raw_store],
      "issue"   => %w[raw_store production],
      "produce" => %w[production qc],
      "qc_pass" => %w[qc fg_store],
      "qc_fail" => %w[qc scrap],
      "ship"    => %w[fg_store customer]
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

    def initialize(product:, lot:, from:, to:, qty:, move_type:, ref:, idempotency_key:)
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
        quants = lock_quants
        # 잠금을 잡은 뒤 다시 본다. 같은 키가 동시에 오면 뒤 요청은 여기서 앞 요청의 결과를 본다.
        existing = StockMove.find_by(idempotency_key: @key)
        next same_as_request!(existing) if existing

        from_quant = quants.fetch(@from.id)
        reject_insufficient!(from_quant) if @from.physical? && from_quant.qty < @qty

        move = StockMove.create!(
          product: @product, lot: @lot, from_location: @from, to_location: @to, qty: @qty,
          move_type: @move_type, ref_type: @ref&.class&.name, ref_id: @ref&.id, idempotency_key: @key
        )
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
      kinds_ok = [@from, @to].all? { |loc| KIND_BY_CODE[loc.code] == loc.kind }
      unless [@from.code, @to.code] == path && kinds_ok
        raise InvalidPath, "#{@move_type} 는 #{path.join('→')} 만 허용한다 (요청: #{@from.code}(#{@from.kind})→#{@to.code}(#{@to.kind}))"
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
