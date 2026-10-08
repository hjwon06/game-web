module Ops
  # 꺼낼 재고 고르기(FIFO + 예약). from_scope(위치 code·Location, 또는 그 배열) 아래 칸의 재고 중
  # 로트가 오래된 순(로트 없는 재고가 가장 오래된 것, 같으면 칸 코드 순)으로 보고, 가용 = quants.qty - active 예약 합 이 qty 이상인 첫 (칸, 로트)를 돌려준다.
  # 다른 작업이 이미 잡은 재고(예약)는 가용에서 빠지므로, 같은 재고를 두 작업이 잡아 완료 때 부족으로 취소되는 일이 없다.
  #
  # partial: true 면 qty 이상인 칸이 없을 때 가용이 있는 가장 오래된 칸을 돌려준다(호출자가 min(qty, available) 만큼만 계획한다).
  # require_lot: true 면 로트 없는 재고는 후보가 아니다(로트별로 이어지는 작업 — pick -> load).
  # 없으면 nil. 재고는 움직이지 않고 예약도 만들지 않는다 — 예약은 고른 뒤 Ops::Plan 이 작업과 함께 만든다.
  class Removal
    Source = Struct.new(:location, :lot, :available)

    def self.choose(product:, qty:, from_scope:, partial: false, require_lot: false)
      new(product, from_scope).choose(qty, partial: partial, require_lot: require_lot)
    end

    def initialize(product, from_scope)
      @product = product
      @from_scope = Array(from_scope)
    end

    def choose(qty, partial:, require_lot:)
      ids = scope_location_ids
      return nil if ids.empty?

      quants = Quant.eager_load(:lot, :location).where(product_id: @product.id, location_id: ids).where("quants.qty > 0")
      quants = quants.where.not(lot_id: nil) if require_lot
      held = Reservation.active.where(product_id: @product.id, location_id: ids).group(:location_id, :lot_id).sum(:qty)
      rows = quants.order(Arel.sql("lots.created_at NULLS FIRST, locations.code, quants.lot_id NULLS FIRST")).to_a
                   .map { |q| [q, q.qty - held.fetch([q.location_id, q.lot_id], 0)] }
                   .select { |_, available| available.positive? }
      quant, available = rows.find { |_, a| a >= qty } || (partial ? rows.first : nil)
      quant && Source.new(quant.location, quant.lot, available)
    end

    private

    # 범위에 적힌 위치와 그 아래 전부(칸이 생기기 전 재고가 창고 자체에 있을 수 있어 자기 자신도 포함한다).
    def scope_location_ids
      roots = @from_scope.map { |loc| loc.is_a?(Location) ? loc.id : Location.find_by!(code: loc.to_s).id }
      return [] if roots.empty?

      sql = Location.sanitize_sql_array([<<~SQL.squish, roots, Location::MAX_DEPTH])
        WITH RECURSIVE tree(id, depth) AS (
          SELECT id, 0 FROM locations WHERE id IN (?)
          UNION ALL
          SELECT l.id, t.depth + 1 FROM locations l JOIN tree t ON l.parent_id = t.id WHERE t.depth < ?
        ) SELECT DISTINCT id FROM tree
      SQL
      Location.connection.select_values(sql).map(&:to_i)
    end
  end
end
