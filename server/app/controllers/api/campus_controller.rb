module Api
  # 단지 화면용 한 방 응답. 3초 폴링 대상이라 쿼리 수가 고정이어야 한다(인증 제외 기본 13개, bins 포함 16개).
  # 작업(tasks)은 서버가 확정한 시작·예상 완료 시각을 내려주고 화면이 server_time 기준으로 보간한다.
  # production_events 는 건드리지 않는다. 집계는 quants.location_id / stock_moves.from_location_id 인덱스를 탄다.
  class CampusController < BaseController
    RECENT_ORDERS = 3
    RECEIVE_WINDOW = 10.minutes
    FLOW_WINDOW = 60.minutes
    MOVES_DEFAULT = 20
    MOVES_MAX = 50
    FG_TOP = 5
    TASKS_MAX = 100
    TASKS_RECENT_DONE = 20
    WORKER_HOME_BUILDING = "hall".freeze # home 위치가 없는 작업자의 기본 건물(가정)
    BIN_ZONE = { "raw_store" => "raw", "fg_store" => "fg" }.freeze
    SIM_NOTE = "수주 고객명은 시드 데이터이며, 입고·생산·검사·출하는 시뮬레이터가 만든다.".freeze

    # 시간 창이 밀리므로 ETag 는 본문 해시다. last_seq·last_move_id·resources·bins 가 모두 본문에 있어 바뀌면 달라진다.
    # server_time 은 매 요청 바뀌므로 해시에서 뺀다(넣으면 304 가 영영 나오지 않는다).
    def show
      after_id = parse_cursor(:after_id)
      after_seq = parse_cursor(:after_seq)
      return render(json: { error: "invalid_after_id" }, status: :bad_request) if after_id == :invalid
      return render(json: { error: "invalid_after_seq" }, status: :bad_request) if after_seq == :invalid

      now = Time.current
      body = payload(now, after_id, after_seq, params[:include].to_s.split(",").include?("bins"))
      return unless stale?(etag: Digest::SHA1.hexdigest(body.to_json), template: false)

      render json: body.merge(server_time: now.utc.iso8601(3))
    end

    private

    def parse_cursor(key)
      raw = params[key]
      return nil if raw.blank?
      return :invalid unless raw.to_s.match?(/\A\d{1,18}\z/)

      raw.to_i
    end

    def payload(now, after_id, after_seq, with_bins)
      rows = Location.pluck(:id, :code, :parent_id) # 쿼리 1: 위치 전부
      loc = rows.to_h { |id, code, _| [code, id] }
      code_of = loc.invert
      building_of = Location.buildings_by_id(rows)
      moves = moves_payload(code_of, after_id)
      statuses = SalesOrder.group(:status).count # 쿼리 2
      flow = flow_window(loc, now)
      pos = purchase_orders(now)
      tasks = tasks_payload(code_of, building_of, after_seq)

      body = { buildings: { office: office(statuses, pos), material: material(loc, pos),
                            hall: hall, qc: qc(loc, flow), shipping: shipping(loc, flow, statuses) },
               moves: moves,
               last_move_id: moves.last&.fetch(:id) || after_id || 0,
               tasks: tasks,
               last_seq: tasks.last&.fetch(:seq) || after_seq || 0,
               resources: resources_payload(building_of),
               sim_note: SIM_NOTE }
      body[:bins] = bins_payload(rows) if with_bins
      body
    end

    # 쿼리 1: 증분이면 seq > after_seq 최대 100건. 첫 진입이면 진행 중 전부 + 최근 완료 20건(취소는 복원 대상이 아니다).
    # ref 는 다형이라 이동 목록처럼 WorkOrder/SalesOrderLine 만 코드로 푼다.
    def tasks_payload(code_of, building_of, after_seq)
      scope = Task.where.not(kind: "count") # 실사는 화면에 아직 없는 작업 종류라 내려주지 않는다(화면은 모르는 종류를 못 그린다)
                  .joins("INNER JOIN products p ON p.id = tasks.product_id")
                  .joins("LEFT JOIN lots l ON l.id = tasks.lot_id")
                  .joins("LEFT JOIN resources r ON r.id = tasks.resource_id")
                  .joins("LEFT JOIN work_orders wo ON tasks.ref_type = 'WorkOrder' AND wo.id = tasks.ref_id")
                  .joins("LEFT JOIN sales_order_lines sol ON tasks.ref_type = 'SalesOrderLine' AND sol.id = tasks.ref_id")
                  .joins("LEFT JOIN sales_orders so ON so.id = sol.sales_order_id")
      scope = if after_seq
                scope.where("tasks.seq > ?", after_seq).limit(TASKS_MAX)
              else
                recent_done = Task.where(status: "done").order(finished_at: :desc, id: :desc).limit(TASKS_RECENT_DONE).select(:id)
                scope.where(status: %w[planned started]).or(scope.where(id: recent_done))
              end
      rows = scope.order("tasks.seq").pluck(
        "tasks.id", "tasks.seq", "tasks.kind", "tasks.status", "r.code", "r.kind", "p.name", "l.lot_no", "tasks.qty",
        "tasks.from_location_id", "tasks.to_location_id", "tasks.planned_at", "tasks.started_at",
        "tasks.expected_finish_at", "tasks.finished_at", Arel.sql("COALESCE(so.so_no, wo.code)")
      )
      rows.map do |id, seq, kind, status, rcode, rkind, product, lot, qty, from, to, planned, started, expected, finished, ref|
        { id: id, seq: seq, kind: kind, status: status,
          resource: rcode && { code: rcode, kind: rkind },
          product: product, lot: lot, qty: num(qty),
          from_code: code_of[from], to_code: code_of[to],
          from_building: building_of[from], to_building: building_of[to],
          planned_at: iso(planned), started_at: iso(started), expected_finish_at: iso(expected), finished_at: iso(finished),
          ref: ref }
      end
    end

    # 쿼리 2개: 자원 전부 + 진행 중(started) 작업. 자원 하나에 started 는 최대 1건이다.
    def resources_payload(building_of)
      running = Task.where(status: "started").where.not(resource_id: nil).where.not(kind: "count").order(:id).pluck(:resource_id, :id).to_h
      Resource.order(:id).pluck(:id, :code, :kind, :home_location_id).map do |id, code, kind, home|
        task_id = running[id]
        { code: code, kind: kind, status: task_id ? "busy" : "idle", current_task_id: task_id,
          home_building: home ? building_of[home] : WORKER_HOME_BUILDING }
      end
    end

    # 쿼리 3개: 칸 위치 + 칸별 재고 + 칸별 active 예약 합(reserved: 다른 작업이 이미 가져가기로 한 수량).
    # level 은 같은 랙 안의 code 순서(1부터)다. 한 칸에 품목이 섞이면 수량이 가장 큰 품목을 product 로 쓴다.
    def bins_payload(rows)
      code_of = rows.to_h { |id, code, _| [id, code] }
      parent_of = rows.to_h { |id, _, parent| [id, parent] }
      bins = Location.where(level: "bin").order(:code).pluck(:id, :code, :parent_id, :capacity_units)
      stock = Quant.joins(:product).where(location_id: bins.map(&:first)).where("quants.qty > 0")
                   .group(:location_id, "products.sku").sum(:qty)
      by_bin = stock.group_by { |(loc_id, _), _| loc_id }
      reserved = Reservation.active.where(location_id: bins.map(&:first)).group(:location_id).sum(:qty)
      level_in_rack = Hash.new(0)
      out = { raw: [], fg: [] }
      bins.each do |id, code, rack_id, capacity|
        zone = BIN_ZONE[zone_root_code(id, code_of, parent_of)] or next
        items = by_bin.fetch(id, [])
        top = items.max_by { |(_, sku), qty| [qty, sku] }
        out[zone.to_sym] << { code: code, rack: code_of[rack_id], level: (level_in_rack[rack_id] += 1), capacity: capacity,
                              qty: num(items.sum { |_, qty| qty }), reserved: num(reserved[id]), product: top&.first&.last }
      end
      out
    end

    def zone_root_code(id, code_of, parent_of)
      (Location::MAX_DEPTH + 1).times do
        return code_of[id] if BIN_ZONE.key?(code_of[id])

        id = parent_of[id] or return nil
      end
      nil
    end

    def iso(time) = time&.utc&.iso8601(3)

    # 발주 요약. 쿼리 2개: 열린 발주 수(confirmed + arrived)와 최근 10분에 도착한 발주 수를 한 번에, 최근 발주 3건.
    # 도착 수는 arrived_at 기준이라 이미 done 이 된 발주도 센다.
    def purchase_orders(now)
      since = now - RECEIVE_WINDOW
      open_sql = PurchaseOrder.sanitize_sql_array(["COUNT(*) FILTER (WHERE status IN (?))", PurchaseOrder::OPEN])
      arrived_sql = PurchaseOrder.sanitize_sql_array(["COUNT(*) FILTER (WHERE arrived_at >= ?)", since])
      open, arrived = PurchaseOrder.where("status IN (?) OR arrived_at >= ?", PurchaseOrder::OPEN, since)
                                   .pick(Arel.sql(open_sql), Arel.sql(arrived_sql))
      recent = PurchaseOrder.joins(:supplier).order(ordered_at: :desc, id: :desc).limit(RECENT_ORDERS)
                            .pluck("purchase_orders.po_no", "suppliers.name", "purchase_orders.status", "purchase_orders.expected_at")
      { open: open.to_i, arrived_10m: arrived.to_i,
        recent: recent.map { |po_no, supplier, status, expected| { po_no: po_no, supplier: supplier, status: status, expected_at: iso(expected) } } }
    end

    def office(statuses, pos)
      recent = SalesOrder.order(created_at: :desc, id: :desc).limit(RECENT_ORDERS) # 쿼리 3
                         .pluck(:so_no, :customer, :due_date, :status)
      { orders: SalesOrder::STATUSES.to_h { |s| [s, statuses.fetch(s, 0)] },
        recent: recent.map { |so_no, customer, due, status| { so_no: so_no, customer: customer, due_date: due, status: status } },
        open_pos: pos[:open], recent_pos: pos[:recent] }
    end

    # 쿼리 4: raw_store 자재별 재고, 쿼리 5: receiving/qc 합(위치별 한 번)
    # received_trucks_10m = 최근 10분에 도착한 발주(PO) 건수. 예전에는 receive 이동 건수였는데 그건 트럭이 아니라 팔레트 수였다.
    def material(loc, pos)
      stock = Quant.joins(:product).where(location_id: loc["raw_store"]).where("quants.qty > 0")
                   .group("products.sku", "products.name").order("products.sku")
                   .pluck("products.sku", "products.name", Arel.sql("SUM(quants.qty)"))
      { raw_store: stock.map { |sku, name, qty| { sku: sku, name: name, qty: num(qty) } },
        receiving_qty: num(on_hand(loc)[loc["receiving"]]),
        received_trucks_10m: pos[:arrived_10m] }
    end

    # 쿼리 6: 기계 전부(상태별 수는 여기서 센다). machines = 기계별 자재 대기. state 는 기계 상태 그대로이고 자재 대기는 별도 표시다.
    def hall
      rows = Machine.order(:id).pluck(:code, :state, :material_short_since)
      counts = rows.map { |_, state, _| state }.tally
      Machine::STATES.to_h { |s| [s, counts.fetch(s, 0)] }.merge(
        machines: rows.map do |code, state, since|
          short = state == "running" && !since.nil?
          { code: code, material_short: short, since: short ? iso(since) : nil }
        end
      )
    end

    def qc(loc, flow)
      passed = flow[:qty]["qc_pass"]
      failed = flow[:qty]["qc_fail"]
      total = passed + failed
      { qty: num(on_hand(loc)[loc["qc"]]), pass_60m: num(passed), fail_60m: num(failed),
        defect_ratio_60m: total.zero? ? nil : (failed / total).to_f.round(4) }
    end

    # 쿼리 8: fg_store 품목별 상위 5
    def shipping(loc, flow, statuses)
      top = Quant.joins(:product).where(location_id: loc["fg_store"])
                 .group("products.sku", "products.name").having("SUM(quants.qty) > 0")
                 .order(Arel.sql("SUM(quants.qty) DESC"), "products.sku").limit(FG_TOP)
                 .pluck("products.sku", "products.name", Arel.sql("SUM(quants.qty)"))
      { fg_store: top.map { |sku, name, qty| { sku: sku, name: name, qty: num(qty) } },
        shipped_60m: num(flow[:qty]["ship"]), partial_orders: statuses.fetch("partial", 0) }
    end

    # receiving/qc 현재고. 한 요청 안에서 한 번만 센다(쿼리 5).
    def on_hand(loc)
      @on_hand ||= Quant.where(location_id: loc.values_at("receiving", "qc")).group(:location_id).sum(:qty)
    end

    # 쿼리 7: 최근 60분 receive/qc_pass/qc_fail/ship 을 from 위치 인덱스로 한 번에.
    # ship 의 출발지는 shipping(출하대)이다. fg_store 는 pick 의 출발지라 거기서는 ship 이 잡히지 않는다.
    def flow_window(loc, now)
      qty = Hash.new(BigDecimal("0"))
      StockMove.where(from_location_id: loc.values_at("supplier", "qc", "shipping"), occurred_at: (now - FLOW_WINDOW)..)
               .group(:move_type).pluck(:move_type, Arel.sql("SUM(qty)"))
               .each { |type, sum| qty[type] = sum }
      { qty: qty }
    end

    # 쿼리 9: 이름·로트·참조 코드를 조인으로 한 번에 가져온다(ref 는 다형이라 ref_type 으로 가른다).
    def moves_payload(code_of, after_id)
      scope = StockMove.joins("INNER JOIN products p ON p.id = stock_moves.product_id")
                       .joins("LEFT JOIN lots l ON l.id = stock_moves.lot_id")
                       .joins("LEFT JOIN work_orders wo ON stock_moves.ref_type = 'WorkOrder' AND wo.id = stock_moves.ref_id")
                       .joins("LEFT JOIN sales_order_lines sol ON stock_moves.ref_type = 'SalesOrderLine' AND sol.id = stock_moves.ref_id")
                       .joins("LEFT JOIN sales_orders so ON so.id = sol.sales_order_id")
      scope = after_id ? scope.where("stock_moves.id > ?", after_id).order("stock_moves.id").limit(MOVES_MAX)
                       : scope.order("stock_moves.id DESC").limit(MOVES_DEFAULT)
      rows = scope.pluck("stock_moves.id", "stock_moves.move_type", "p.name", "l.lot_no", "stock_moves.qty",
                         "stock_moves.from_location_id", "stock_moves.to_location_id", "stock_moves.occurred_at",
                         Arel.sql("COALESCE(so.so_no, wo.code)"))
      rows.reverse! unless after_id
      rows.map do |id, type, product, lot, qty, from, to, at, ref|
        { id: id, type: type, product: product, lot: lot, qty: num(qty), from_code: code_of[from], to_code: code_of[to],
          at: at.iso8601(3), ref: ref }
      end
    end

    def num(value)
      v = BigDecimal((value || 0).to_s)
      v.frac.zero? ? v.to_i : v.to_f
    end
  end
end
