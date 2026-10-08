module Api
  # 단지 화면용 한 방 응답. 3초 폴링 대상이라 쿼리 수가 고정이어야 한다(인증 제외 9개).
  # production_events 는 건드리지 않는다. 집계는 quants.location_id / stock_moves.from_location_id 인덱스를 탄다.
  class CampusController < BaseController
    RECENT_ORDERS = 3
    RECEIVE_WINDOW = 10.minutes
    FLOW_WINDOW = 60.minutes
    MOVES_DEFAULT = 20
    MOVES_MAX = 50
    FG_TOP = 5
    SIM_NOTE = "수주 고객명은 시드 데이터이며, 입고·생산·검사·출하는 시뮬레이터가 만든다.".freeze

    # 시간 창이 밀리므로 ETag 는 본문 해시다. moves 도 본문에 들어 있어 새 이동이 생기면 바뀐다.
    def show
      after_id = parse_after_id
      return render(json: { error: "invalid_after_id" }, status: :bad_request) if after_id == :invalid

      body = payload(Time.current, after_id)
      return unless stale?(etag: Digest::SHA1.hexdigest(body.to_json), template: false)

      render json: body
    end

    private

    def parse_after_id
      raw = params[:after_id]
      return nil if raw.blank?
      return :invalid unless raw.to_s.match?(/\A\d{1,18}\z/)

      raw.to_i
    end

    def payload(now, after_id)
      loc = Location.pluck(:code, :id).to_h # 쿼리 1: 위치 전부
      code_of = loc.invert
      moves = moves_payload(code_of, after_id)
      statuses = SalesOrder.group(:status).count # 쿼리 2
      flow = flow_window(loc, now)

      { buildings: { office: office(statuses), material: material(loc, flow),
                     hall: hall, qc: qc(loc, flow), shipping: shipping(loc, flow, statuses) },
        moves: moves,
        last_move_id: moves.last&.fetch(:id) || after_id || 0,
        sim_note: SIM_NOTE }
    end

    def office(statuses)
      recent = SalesOrder.order(created_at: :desc, id: :desc).limit(RECENT_ORDERS) # 쿼리 3
                         .pluck(:so_no, :customer, :due_date, :status)
      { orders: SalesOrder::STATUSES.to_h { |s| [s, statuses.fetch(s, 0)] },
        recent: recent.map { |so_no, customer, due, status| { so_no: so_no, customer: customer, due_date: due, status: status } } }
    end

    # 쿼리 4: raw_store 자재별 재고, 쿼리 5: receiving/qc 합(위치별 한 번)
    def material(loc, flow)
      stock = Quant.joins(:product).where(location_id: loc["raw_store"]).where("quants.qty > 0")
                   .group("products.sku", "products.name").order("products.sku")
                   .pluck("products.sku", "products.name", Arel.sql("SUM(quants.qty)"))
      { raw_store: stock.map { |sku, name, qty| { sku: sku, name: name, qty: num(qty) } },
        receiving_qty: num(on_hand(loc)[loc["receiving"]]),
        received_trucks_10m: flow[:trucks] }
    end

    def hall
      counts = Machine.group(:state).count # 쿼리 6
      Machine::STATES.to_h { |s| [s, counts.fetch(s, 0)] }
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

    # 쿼리 7: 최근 60분 receive/qc_pass/qc_fail/ship 을 from 위치 인덱스로 한 번에. 트럭 = 최근 10분 receive 건수.
    # ship 의 출발지는 shipping(출하대)이다. fg_store 는 pick 의 출발지라 거기서는 ship 이 잡히지 않는다.
    def flow_window(loc, now)
      qty = Hash.new(BigDecimal("0"))
      trucks = 0
      trucks_sql = StockMove.sanitize_sql_array(
        ["COUNT(*) FILTER (WHERE move_type = 'receive' AND occurred_at >= ?)", now - RECEIVE_WINDOW]
      )
      StockMove.where(from_location_id: loc.values_at("supplier", "qc", "shipping"), occurred_at: (now - FLOW_WINDOW)..)
               .group(:move_type).pluck(:move_type, Arel.sql("SUM(qty)"), Arel.sql(trucks_sql))
               .each do |type, sum, recv|
        qty[type] = sum
        trucks += recv.to_i
      end
      { qty: qty, trucks: trucks }
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
