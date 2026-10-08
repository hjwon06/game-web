module Ops
  # 적치할 칸 고르기. 규칙(putaway_rules)을 priority 순으로 보고, 규칙마다 그 구역·랙 하위 칸 중
  #   ① 같은 품목이 있고 남은 용량 >= qty 인 칸(코드 순 첫 칸) ② 빈 칸(용량 >= qty, 코드 순 첫 칸) 을 찾는다. 첫 규칙에서 찾으면 거기서 끝이다.
  # 규칙은 이 품목 전용(product_id = 품목)과 전 품목용(product_id NULL)이 함께 걸리고, priority 가 같으면 전용이 먼저, 그다음 위치 코드 순이다.
  # 어느 규칙에도 칸이 없으면 nil — 호출자는 입고대·검사대에 두고 다음 호출에 다시 본다.
  #
  # 품목 종류가 받는 창고(raw -> raw_store, fg -> fg_store) 밖의 칸은 규칙이 가리켜도 쓰지 않는다. 전 품목 규칙(완제품 랙)에 자재가 딸려 가지 않게 한다.
  # 칸 상태는 DB 에서 읽는다: 현재고 + 이미 계획된 적치(planned/started)의 합이 사용량이다. 계획 직후 다시 불러도 방금 계획분이 반영된다.
  class Putaway
    OPEN = %w[planned started].freeze
    ZONE_BY_KIND = { "raw" => "raw_store", "fg" => "fg_store" }.freeze

    # products: 현재고나 계획된 적치가 있는 품목 id 집합
    Bin = Struct.new(:id, :code, :capacity, :used, :products)

    # 칸(Location) 또는 nil.
    def self.choose(product:, qty:) = new(product).choose(qty)

    # 이 품목이 규칙상 쓸 수 있는 칸 전부(규칙 순서, 중복 제거). 트럭에 실을 양을 정할 때 남은 자리를 센다.
    def self.bins(product:) = new(product).groups.flatten

    def initialize(product)
      @product = product
    end

    def choose(qty)
      groups.each do |bins|
        bin = bins.find { |b| b.products.include?(@product.id) && b.capacity - b.used >= qty } ||
              bins.find { |b| b.products.empty? && b.capacity >= qty }
        return Location.find(bin.id) if bin
      end
      nil
    end

    # 규칙 순서대로 [그 규칙의 칸들(코드 순)] 의 배열. 앞 규칙에 이미 나온 칸은 뒤 규칙에서 뺀다.
    def groups
      root_ids = rule_location_ids
      return [] if root_ids.empty?

      by_root, allowed = bins_by_root(root_ids)
      seen = Set.new
      per_rule = root_ids.map do |root|
        (by_root[root] || []).select { |id, _, _| (allowed.nil? || allowed.include?(id)) && seen.add?(id) }
      end
      usage = usage_by_bin(per_rule.flatten(1).map(&:first))
      per_rule.map do |rows|
        rows.map do |id, code, capacity|
          mine = usage.fetch(id, [])
          Bin.new(id, code, capacity || Float::INFINITY, mine.sum { |_, qty| qty }, mine.map { |product_id, _| product_id }.to_set)
        end
      end.reject(&:empty?)
    end

    private

    # 이 품목에 걸리는 활성 규칙의 위치 id. 규칙 순서(priority -> 전용 먼저 -> 위치 코드 -> id).
    def rule_location_ids
      PutawayRule.active.joins(:location).where(product_id: [@product.id, nil])
                 .order(:priority, Arel.sql("putaway_rules.product_id IS NULL"), "locations.code", "putaway_rules.id")
                 .pluck(:location_id).uniq
    end

    # 한 번의 재귀 쿼리로 [{ 루트 id => [[칸 id, code, capacity_units]...] }, 허용 칸 id 집합(없으면 nil)].
    # 허용 집합 = 품목 종류가 받는 창고 아래 칸. 창고 자체도 루트에 넣어 같은 쿼리에서 얻는다.
    def bins_by_root(root_ids)
      zone = ZONE_BY_KIND[@product.kind]
      sql = Location.sanitize_sql_array([<<~SQL.squish, root_ids, zone, Location::MAX_DEPTH])
        WITH RECURSIVE tree(root_id, id, depth) AS (
          SELECT id, id, 0 FROM locations WHERE id IN (?) OR code = ?
          UNION ALL
          SELECT t.root_id, l.id, t.depth + 1 FROM locations l JOIN tree t ON l.parent_id = t.id WHERE t.depth < ?
        )
        SELECT t.root_id, r.code, l.id, l.code, l.capacity_units
        FROM tree t JOIN locations l ON l.id = t.id JOIN locations r ON r.id = t.root_id
        WHERE l.level = 'bin' ORDER BY l.code
      SQL
      rows = Location.connection.select_rows(sql)
      allowed = zone && rows.select { |_, root_code, *| root_code == zone }.to_set { |_, _, id, *| id.to_i }
      by_root = rows.group_by { |root_id, *| root_id.to_i }
                    .transform_values { |list| list.map { |_, _, id, code, capacity| [id.to_i, code, capacity&.to_i] } }
      [by_root, allowed]
    end

    # { 칸 id => [[품목 id, 수량]...] } 현재고(> 0) + 계획된 적치. 칸이 없으면 쿼리하지 않는다.
    def usage_by_bin(bin_ids)
      return {} if bin_ids.empty?

      on_hand = Quant.where(location_id: bin_ids).where("qty > 0").group(:location_id, :product_id).sum(:qty)
      planned = Task.where(kind: "putaway", status: OPEN, to_location_id: bin_ids).group(:to_location_id, :product_id).sum(:qty)
      on_hand.merge(planned) { |_, a, b| a + b }.group_by { |(loc, _), _| loc }
             .transform_values { |list| list.map { |(_, product_id), qty| [product_id, qty] } }
    end
  end
end
