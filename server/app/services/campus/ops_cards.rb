module Campus
  # 3D 관제 카드 6묶음(kpi·trucks·forklifts·docks·shipment·sites). /api/campus?include=ops 일 때만 붙는다.
  # 300ms 폴링 대상이라 쿼리 수가 데이터 양과 무관해야 한다: 묶음마다 쿼리를 고정 개수로 쓰고 나머지는 메모리에서 센다(최대 18개).
  # 진행률은 서버 시각(now) 기준으로 계산해 내려준다. 그래서 진행 중인 작업이 있으면 본문이 매번 달라진다(ETag 304 는 한가할 때만 난다).
  class OpsCards
    PALLET = Simulation::Config::PALLET_QTY
    TRUCKS_MAX = 8
    SITE_TOP = 5
    DELTA_WINDOW = 1.hour
    ON_TIME_WINDOW = 7.days
    STOCK_BUILDINGS = %w[material shipping_wh shipping_dock].freeze # 팔레트 수에 드는 건물: 자재창고·입고대 / 완제품창고 / 출하대
    SITE_OF = { "material" => "mat", "shipping_wh" => "ship", "shipping_dock" => "ship", "qc" => "qc", "hall" => "prod" }.freeze
    SITE_KEYS = %w[mat ship qc prod].freeze
    VIRTUAL_CODES = Location::DEFAULTS.filter_map { |code, _name, kind, _role| code if kind == "virtual" }.freeze
    STATUS_RANK = { "unloading" => 0, "loading" => 0, "docking" => 1, "en_route" => 2 }.freeze

    # rows: Location.pluck(:id, :code, :parent_id) 전체(컨트롤러가 이미 읽었다). so_no: 출하 추적 대상 수주 번호(없으면 가장 최근에 움직인 열린 수주).
    def self.call(now:, rows:, so_no: nil) = new(now: now, rows: rows, so_no: so_no).call

    def initialize(now:, rows:, so_no:)
      @now = now
      @code_of = rows.to_h { |id, code, _| [id, code] }
      @building_of = Location.buildings_by_id(rows)
      @so_no = so_no.to_s.strip[0, 40].presence
    end

    def call
      resources = Resource.order(:id).pluck(:id, :code, :kind) # 쿼리 1
      docks = dock_tasks
      trucks = truck_list(docks)
      forks, fork_busy = forklifts(resources.select { |_, _, kind| kind == "forklift" })
      { kpi: kpi(trucks), trucks: trucks.first(TRUCKS_MAX), forklifts: forks,
        docks: docks_payload(resources, docks), shipment: shipment, sites: sites(fork_busy, resources.count { |_, _, k| k == "forklift" }) }
    end

    private

    def iso(time) = time&.utc&.iso8601(3)

    def num(value) = (v = BigDecimal((value || 0).to_s)).frac.zero? ? v.to_i : v.to_f

    # --- 하차·상차 작업 -------------------------------------------------------------------------------

    # 쿼리 1: 열린(planned·started) unload·load 작업과 그 발주/수주/도크를 조인으로 한 번에. 트럭과 도크 점유가 이 행에서 나온다.
    # 정렬은 started 먼저, 그다음 계획 시각 순이다. 도크의 "현재 트럭" 판정이 이 순서를 따른다.
    def dock_tasks
      rows = Task.where(kind: %w[unload load], status: %w[planned started])
                 .joins("LEFT JOIN resources r ON r.id = tasks.resource_id")
                 .joins("LEFT JOIN purchase_order_lines pol ON tasks.ref_type = 'PurchaseOrderLine' AND pol.id = tasks.ref_id")
                 .joins("LEFT JOIN purchase_orders po ON po.id = pol.purchase_order_id")
                 .joins("LEFT JOIN suppliers s ON s.id = po.supplier_id")
                 .joins("LEFT JOIN sales_order_lines sol ON tasks.ref_type = 'SalesOrderLine' AND sol.id = tasks.ref_id")
                 .joins("LEFT JOIN sales_orders so ON so.id = sol.sales_order_id")
                 .pluck("tasks.id", "tasks.kind", "tasks.status", "r.code", "po.id", "po.po_no", "s.name", "so.id", "so.so_no", "so.customer",
                        "tasks.planned_at", "tasks.expected_finish_at")
      rows.filter_map do |id, kind, status, dock, po_id, po_no, supplier, so_id, so_no, customer, planned, expected|
        inbound = kind == "unload"
        key = inbound ? po_id : so_id
        next unless key

        { id: id, type: inbound ? "in" : "out", key: key, no: inbound ? po_no : so_no, party: inbound ? supplier : customer,
          started: status == "started", dock: dock, planned_at: planned, expected: expected }
      end.sort_by { |t| [t[:started] ? 0 : 1, t[:planned_at], t[:id]] }
    end

    # 트럭 = 열린 하차가 있는 도착 발주(in) + 열린 상차가 있는 수주(out) + 아직 오는 중인 발주.
    # 쿼리 3개: 끝난 하차 수(발주별), 끝난 상차 수(수주별), 오는 중 발주 최대 8건(+ 팔레트 수).
    def truck_list(tasks)
      done_in = done_counts("unload", "PurchaseOrderLine", "purchase_order_lines", "purchase_order_id", tasks.select { |t| t[:type] == "in" }.map { |t| t[:key] }.uniq)
      done_out = done_counts("load", "SalesOrderLine", "sales_order_lines", "sales_order_id", tasks.select { |t| t[:type] == "out" }.map { |t| t[:key] }.uniq)

      on_site = tasks.group_by { |t| [t[:type], t[:key]] }.map do |(type, key), list|
        open = list.size
        done = (type == "in" ? done_in : done_out).fetch(key, 0)
        started = list.find { |t| t[:started] }
        dock = (started || list.find { |t| t[:dock] })&.fetch(:dock)
        status = started ? (type == "in" ? "unloading" : "loading") : "docking"
        { type: type, no: list.first[:no], party: list.first[:party], dock: dock, status: status, done: done, total: done + open,
          eta: iso(list.filter_map { |t| t[:expected] }.max) }
      end

      (on_site + en_route).sort_by { |t| [STATUS_RANK.fetch(t[:status]), t[:eta].to_s] }
    end

    def done_counts(kind, ref_type, line_table, parent_column, ids)
      Task.where(kind: kind, status: "done", ref_type: ref_type)
          .joins("JOIN #{line_table} l ON l.id = tasks.ref_id")
          .where("l.#{parent_column} IN (?)", ids)
          .group("l.#{parent_column}").count
    end

    def en_route
      PurchaseOrder.where(status: "confirmed").joins(:supplier).left_joins(:lines)
                   .group("purchase_orders.id", "suppliers.name").order("purchase_orders.expected_at", "purchase_orders.id").limit(TRUCKS_MAX)
                   .pluck("purchase_orders.po_no", "suppliers.name", "purchase_orders.expected_at",
                          Arel.sql("COALESCE(SUM(CEIL(purchase_order_lines.qty_ordered / #{PALLET})), 0)"))
                   .map do |po_no, supplier, expected, pallets|
        { type: "in", no: po_no, party: supplier, dock: nil, status: "en_route", done: 0, total: pallets.to_i, eta: iso(expected) }
      end
    end

    # --- O1 kpi ---------------------------------------------------------------------------------

    def kpi(trucks)
      on_hand, net = pallet_quantities
      now_pallets = (on_hand / PALLET).round
      site = trucks.reject { |t| t[:status] == "en_route" }
      ins = site.count { |t| t[:type] == "in" }
      outs = site.count { |t| t[:type] == "out" }
      { pallets_on_hand: now_pallets, pallets_delta_1h: now_pallets - ((on_hand - net) / PALLET).round,
        trucks_on_site: ins + outs, trucks_in: ins, trucks_out: outs, on_time_rate: on_time_rate }
    end

    # 쿼리 2: 물리 칸·입고대·출하대 현재고 합과, 최근 1시간 그 구역 경계를 넘나든 원장 순증감.
    # 구역 안끼리의 이동(putaway·pick)은 합이 변하지 않으니 경계를 넘는 이동만 본다: 들어온 것 - 나간 것. 1시간 전 재고 = 현재고 - 순증감.
    def pallet_quantities
      inside = @building_of.filter_map { |id, b| id if STOCK_BUILDINGS.include?(b) }
      outside = @code_of.keys - inside
      on_hand = Quant.where(location_id: inside).where("qty > 0").sum(:qty)
      delta_sql = StockMove.sanitize_sql_array(["COALESCE(SUM(CASE WHEN to_location_id IN (?) THEN qty ELSE -qty END), 0)", inside])
      net = StockMove.where(occurred_at: (@now - DELTA_WINDOW)..)
                     .where("(to_location_id IN (:i) AND from_location_id IN (:o)) OR (from_location_id IN (:i) AND to_location_id IN (:o))",
                            i: inside, o: outside)
                     .pick(Arel.sql(delta_sql))
      [on_hand, net || 0]
    end

    # 쿼리 1: 최근 7일 안에 마지막 출하가 끝난 done 수주 중 납기일 이전(당일 포함) 출하 비율. 표본이 없으면 nil.
    def on_time_rate
      sql = StockMove.sanitize_sql_array([<<~SQL.squish, Time.zone.tzinfo.name, @now - ON_TIME_WINDOW])
        SELECT COUNT(*) AS total, COUNT(*) FILTER (WHERE (x.shipped_at AT TIME ZONE ?)::date <= x.due_date) AS on_time
        FROM (
          SELECT so.id, so.due_date, MAX(sm.occurred_at) AS shipped_at
          FROM sales_orders so
          JOIN sales_order_lines sol ON sol.sales_order_id = so.id
          JOIN stock_moves sm ON sm.ref_type = 'SalesOrderLine' AND sm.ref_id = sol.id AND sm.move_type = 'ship'
          WHERE so.status = 'done' AND so.due_date IS NOT NULL
          GROUP BY so.id, so.due_date
          HAVING MAX(sm.occurred_at) >= ?
        ) x
      SQL
      row = StockMove.connection.select_one(sql)
      total = row["total"].to_i
      total.zero? ? nil : (row["on_time"].to_i * 100.0 / total).round(1)
    end

    # --- O3 forklifts / O4 docks ----------------------------------------------------------------

    # 쿼리 2: 진행 중 작업(품목 조인), 자원별 대기 건수. 두 번째 반환값은 건물(사이트)별 일하는 지게차 수다.
    def forklifts(forks)
      ids = forks.map(&:first)
      running = Task.where(status: "started", resource_id: ids).joins(:product)
                    .pluck("tasks.resource_id", "tasks.kind", "products.name", "tasks.qty", "tasks.from_location_id", "tasks.to_location_id",
                           "tasks.started_at", "tasks.expected_finish_at").index_by(&:first)
      waiting = Task.where(status: "planned", resource_id: ids).group(:resource_id).count
      busy = Hash.new(0)
      list = forks.map do |id, code, _|
        _, kind, product, qty, from, to, started, expected = running[id]
        if running[id]
          [from, to].filter_map { |loc| SITE_OF[@building_of[loc]] }.uniq.each { |site| busy[site] += 1 }
          task = { kind: kind, product: product, qty: num(qty), from_code: @code_of[from], to_code: @code_of[to] }
        end
        { code: code, task: task, progress: task ? progress(started, expected) : nil, planned_count: waiting.fetch(id, 0) }
      end
      [list, busy]
    end

    # 시작~예상 완료 대비 지금, 0~100 정수. 예상 완료가 없거나 시작보다 앞서면 0.
    def progress(started, expected)
      return 0 if started.nil? || expected.nil? || expected <= started

      (((@now - started) / (expected - started)) * 100).clamp(0, 100).round
    end

    # 점유 = 그 도크에 열린 작업(planned·started)이 있다. 현재 트럭 = started 먼저, 없으면 가장 일찍 계획된 작업의 발주/수주 번호.
    def docks_payload(resources, tasks)
      current = {}
      tasks.each { |t| current[t[:dock]] ||= t[:no] if t[:dock] }
      resources.filter_map do |_, code, kind|
        next unless %w[dock_in dock_out].include?(kind)

        { code: code, kind: kind, occupied: current.key?(code), truck: current[code] }
      end
    end

    # --- O5 shipment ----------------------------------------------------------------------------

    # 쿼리 4: 대상 수주, 작업 집계, 주문량 합, 출하 이동 시각. 수주를 못 찾으면 쿼리 1개만 쓰고 nil.
    def shipment
      id, so_no, customer, created_at, status = target_order
      return nil unless id

      tasks = Task.where(kind: %w[pick load]).where.not(status: "cancelled")
                  .joins("JOIN sales_order_lines sol ON tasks.ref_type = 'SalesOrderLine' AND sol.id = tasks.ref_id")
                  .where("sol.sales_order_id = ?", id)
                  .pluck("tasks.kind", "tasks.status", "tasks.qty", "tasks.planned_at", "tasks.started_at", "tasks.finished_at")
      lines = SalesOrderLine.where(sales_order_id: id)
      ordered = lines.sum(:ordered_qty)
      ships = StockMove.where(move_type: "ship", ref_type: "SalesOrderLine", ref_id: lines.select(:id)).order(:occurred_at).pluck(:occurred_at, :qty)
      stages = round_stages(tasks, ships, ordered)
      at = [created_at, *stages.values_at(:picked, :staged, :loaded, :shipped)]
      # 단계 시각은 단조 증가해야 한다. 앞 단계보다 이른 시각은 다른 회차의 흔적이니 비운다.
      floor = created_at
      %i[picked staged loaded shipped].each_with_index do |key, i|
        if at[i + 1] && at[i + 1] < floor then at[i + 1] = nil
        elsif at[i + 1] then floor = at[i + 1]
        end
      end
      { so_no: so_no, customer: customer,
        stages: [{ key: "received", at: iso(at[0]) }, { key: "picked", at: iso(at[1]) }, { key: "staged", at: iso(at[2]) },
                 { key: "loaded", at: iso(at[3]) }, { key: "shipped", at: iso(at[4]) }] }
    end

    # 분할 출하 수주는 출하가 여러 번이다. 현재 회차 = 마지막 ship 이동 이후의 활동, 그 뒤 활동이 없으면 마지막 회차 전체(직전 ship 이후 ~ 마지막 ship).
    # picked·staged·loaded·shipped 는 같은 회차 이벤트만 쓴다. 현재 회차가 아직 안 나갔으면 shipped 는 비어 있다.
    # staged = 그 회차 pick 이 모두 끝난 시각: 열린 pick 이 없고 끝난 pick 수량이 (주문량 - 이전 회차 출하량) 이상. 재고가 모자라 일부만 pick 했으면 비어 있다.
    def round_stages(tasks, ships, ordered)
      active_at = ->(t) { t[5] || t[4] || t[3] }
      last_ship = ships.last&.first
      later = last_ship && tasks.any? { |t| active_at.(t) > last_ship }
      if ships.empty? || later
        from, upto, shipped, before = last_ship, nil, nil, ships
      else
        from, upto, shipped, before = ships[-2]&.first, last_ship, last_ship, ships[0...-1]
      end
      round = tasks.select { |t| (from.nil? || active_at.(t) > from) && (upto.nil? || active_at.(t) <= upto) }
      picks = round.select { |t| t[0] == "pick" }
      done = picks.select { |t| t[1] == "done" && t[5] }
      remaining = ordered - before.sum { |_, qty| qty }
      staged = done.any? && done.size == picks.size && done.sum { |t| t[2] } >= remaining ? done.map { |t| t[5] }.max : nil
      { picked: done.map { |t| t[5] }.min, staged: staged, loaded: round.select { |t| t[0] == "load" }.filter_map { |t| t[4] }.min, shipped: shipped }
    end

    # ?so= 가 있으면 그 수주(상태 무관). 없으면 열린(open·partial) 수주 중 pick·load 작업이 가장 최근에 바뀐 것, 작업이 없으면 가장 새 수주.
    def target_order
      cols = %w[sales_orders.id sales_orders.so_no sales_orders.customer sales_orders.created_at sales_orders.status]
      return SalesOrder.where(so_no: @so_no).pick(*cols) if @so_no

      SalesOrder.where(status: %w[open partial])
                .joins("LEFT JOIN sales_order_lines sol ON sol.sales_order_id = sales_orders.id")
                .joins("LEFT JOIN tasks t ON t.ref_type = 'SalesOrderLine' AND t.ref_id = sol.id AND t.kind IN ('pick','load')")
                .group("sales_orders.id")
                .order(Arel.sql("GREATEST(sales_orders.created_at, MAX(t.updated_at)) DESC NULLS LAST"), "sales_orders.id DESC")
                .pick(*cols)
    end

    # --- O6 sites -------------------------------------------------------------------------------

    # 쿼리 4: 건물 재고(칸·구역·위치 한 번), 재주문점, 수요(BOM·작업지시 2개).
    # low = 재주문점이 있고 수요가 있는 품목의 4개 건물 합계 재고(입고대·자재창고·라인 공급대 등)가 min_minutes 분어치 미만이다.
    # 운반 중·발주한 수량은 넣지 않는다(재주문 판단의 보유 분수보다 조금 일찍 low 로 보인다).
    def sites(busy, forklift_count)
      site_of_id = @building_of.each_with_object({}) do |(id, b), h|
        site = SITE_OF[b]
        h[id] = site if site && !VIRTUAL_CODES.include?(@code_of[id])
      end
      stock = Quant.joins(:product).where(location_id: site_of_id.keys).where("quants.qty > 0")
                   .group("quants.location_id", "products.id", "products.name").sum("quants.qty")
      by_site = Hash.new { |h, k| h[k] = Hash.new(0) }
      names = {}
      total = Hash.new(0)
      stock.each do |(loc, pid, name), qty|
        by_site[site_of_id.fetch(loc)][pid] += qty
        names[pid] = name
        total[pid] += qty
      end
      min_of = ReorderRule.by_product(total.keys).transform_values(&:min_minutes)
      demand = Simulation::Inbound.demand_per_minute

      SITE_KEYS.to_h do |site|
        top = by_site[site].sort_by { |pid, qty| [-qty, names[pid]] }.first(SITE_TOP).map do |pid, qty|
          low = min_of[pid] && demand[pid] && total[pid] / demand[pid] < min_of[pid]
          { product: names[pid], qty: num(qty), status: low ? "low" : "in_stock" }
        end
        rate = forklift_count.zero? ? 0 : (busy[site] * 100.0 / forklift_count).round
        [site, { items: top, forklift_rate: rate }]
      end
    end
  end
end
