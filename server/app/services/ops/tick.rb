module Ops
  # 시계를 now 로 옮긴다: 시작 시각이 된 planned 는 started, 예상 완료가 지난 started 는 done(재고 이동 1건).
  # 자원 하나가 Tick 1회에 끝내는 작업은 MAX_FINISH_PER_RESOURCE(1)건이다. 오래 멈췄다 재개돼도 밀린 작업은 다음 Tick 들이 하나씩 이어서 끝낸다.
  # 재실행해도 안전하다 — 이동의 멱등키가 "task:<id>" 이고, 이미 done 인 작업은 다시 건드리지 않는다.
  #
  # 작업 종류 → 완료 순간의 이동:
  #   unload → receive, putaway → putaway (qc 에서 나가는 적치는 qc_pass), feed → feed, pick → pick,
  #   load → ship (Inventory::Ship: 수주 라인 출하량·수주 상태도 같이 갱신)
  #   inspect → 불량분 qc_fail(qc → scrap) 1건. 불량이 0이면 이동 없이 done. 합격분 적치(qc_pass)는 같은 트랜잭션에서 바로 계획한다
  #             (칸이 없으면 Simulation::Inspection 이 다음 호출에 이어서 계획한다).
  #   count → 이동 없이 done. cycle_counts 행을 남기고, 센 수량이 시스템 수량과 다르면 adjust 이동(Ops::CycleCount)으로 맞춘다.
  # 하차(unload)의 ref 가 발주 라인(PurchaseOrderLine)이면 같은 트랜잭션에서 그 라인 qty_received 를 올리고, 전 라인을 받았으면 발주를 done 으로 닫는다.
  class Tick
    # 키: "task:<id>". inspect 의 불량 이동 키는 Inventory::Inspect 가 "qc_fail:task:<id>" 로 만든다.
    MOVE_TYPE = { "unload" => "receive", "putaway" => "putaway", "feed" => "feed", "pick" => "pick", "load" => "ship" }.freeze
    # 이 오류들은 "그 작업이 안 되는 것"이라 작업만 취소한다. 그 밖의 오류(DB 장애 등)는 숨기지 않고 올린다.
    TASK_FAILURES = [
      Inventory::InsufficientStock, Inventory::CapacityExceeded, Inventory::Move::InvalidPath,
      Inventory::IdempotencyConflict, Inventory::Ship::OverShipment
    ].freeze

    MAX_FINISH_PER_RESOURCE = 1 # Tick 1회에 자원 하나가 끝내는 작업 수 상한

    Result = Struct.new(:started, :done, :cancelled, keyword_init: true)

    def self.call(now:) = new(now: now).call

    def initialize(now:)
      @now = now
    end

    def call
      @result = Result.new(started: [], done: [], cancelled: [])
      resource_ids.each { |id| process_resource(id) }
      @result
    end

    private

    # 오름차순. 자원 하나씩 짧은 트랜잭션으로 처리해 한 자원의 잠금이 다른 자원을 기다리게 하지 않는다.
    def resource_ids
      Task.where(status: %w[planned started]).where.not(resource_id: nil).distinct.order(:resource_id).pluck(:resource_id)
    end

    def process_resource(id)
      Task.transaction do
        Resource.lock.find(id) # 같은 자원을 만지는 Plan·Tick 을 직렬화한다
        finished = 0
        loop do
          running = Task.where(resource_id: id, status: "started").order(:id).first
          if running
            break unless running.expected_finish_at && running.expected_finish_at <= @now
            # 오래 멈췄다 돌아와도 한 번에 한 건만 끝낸다. 나머지는 다음 Tick 이 이어서 한다(이동이 한 순간에 몰리지 않게).
            break if finished >= MAX_FINISH_PER_RESOURCE

            finish(running)
            finished += 1
          else
            nxt = Task.where(resource_id: id, status: "planned").where("planned_at <= ?", @now).order(:planned_at, :id).first
            break unless nxt

            start(nxt)
          end
        end
      end
    end

    def start(task)
      task.update!(status: "started", started_at: task.planned_at)
      @result.started << task.id
    end

    def finish(task)
      finished_at = task.expected_finish_at
      begin
        # 이동이 실패하면 savepoint 째로 되돌아가 원장·재고에 흔적이 없다.
        Task.transaction(requires_new: true) do
          move = complete(task)
          # 예약은 Task 가 상태 저장과 같은 트랜잭션에서 닫는다(done -> consumed). 이동이 되돌아가면 예약도 active 로 남는다.
          task.update!(status: "done", finished_at: finished_at, stock_move: move)
          # 발주 하차라면 라인 입고량도 같은 트랜잭션에서 올린다. 이동이 되돌아가면 입고량도 오르지 않는다.
          receive_order_line(task)
          # 검사 완료: 합격분은 같은 트랜잭션에서 적치 예약으로 넘긴다. 검사 예약이 consumed 로 닫힌 뒤 다른 작업이 qc 재고를 가져가기 전이다.
          Simulation::Inspection.plan_putaway_for(task, now: @now) if task.kind == "inspect"
        end
        @result.done << task.id
      rescue *TASK_FAILURES => e
        # 작업 취소와 예약 해제(cancelled -> released)가 process_resource 의 같은 트랜잭션에서 커밋된다.
        task.update!(status: "cancelled", finished_at: finished_at, cancel_reason: "#{e.class.name.demodulize}: #{e.message}")
        PurchaseOrder.unload_cancelled!(task)
        @result.cancelled << task.id
      end
    end

    # 발주 라인(ref)을 가리키는 하차가 끝났으면 라인 qty_received 를 올리고, 전 라인을 다 받았으면 발주를 done 으로 닫는다.
    def receive_order_line(task)
      return unless task.kind == "unload" && task.ref_type == "PurchaseOrderLine"

      PurchaseOrderLine.find_by(id: task.ref_id)&.receive!(task.qty)
    end

    # 작업의 재고 이동을 만들고 그 이동을 돌려준다(없으면 nil).
    def complete(task)
      case task.kind
      when "inspect" then fail_inspected(task)
      when "count" then count(task)
      when "load" then ship(task) || move(task, "ship")
      else
        move(task, move_type_for(task)).tap { |m| record_pass(task, m) if m.move_type == "qc_pass" }
      end
    end

    # qc 에서 나가는 적치는 합격 이동(qc_pass), 그 밖의 적치는 입고 적치다.
    def move_type_for(task)
      return "qc_pass" if task.kind == "putaway" && task.from_location.code == "qc"

      MOVE_TYPE.fetch(task.kind)
    end

    def move(task, move_type)
      Inventory::Move.call(
        product: task.product, lot: task.lot, from: task.from_location, to: task.to_location, qty: task.qty,
        move_type: move_type, ref: task, idempotency_key: "task:#{task.id}"
      )
    end

    # 출하: 수주 라인(ref)이 있으면 Inventory::Ship 으로 출하량·수주 상태까지 갱신한다. 라인이 없으면 nil(일반 이동으로 대체).
    def ship(task)
      return nil unless task.ref_type == "SalesOrderLine"

      line = SalesOrderLine.find_by(id: task.ref_id) or return nil
      Inventory::Ship.call(sales_order_line: line, lot: task.lot, qty: task.qty, idempotency_key: "task:#{task.id}")
    end

    # 실사 완료: 실사 기록을 남긴다. 작업 자체는 이동이 없어 nil 이다(시뮬에서는 센 수량 = 시스템 수량이라 조정도 없다).
    def count(task)
      Ops::CycleCount.complete(task, at: task.expected_finish_at)
      nil
    end

    # 검사 완료: 작업지시의 불량률만큼 qc_fail(qc → scrap)을 이 작업의 완료로 만든다. 합격분은 이동하지 않는다.
    def fail_inspected(task)
      order = WorkOrder.find_by(id: task.ref_id) if task.ref_type == "WorkOrder"
      return nil unless order && task.lot

      fail_qty = Simulation::Inspection.fail_qty(order, task.qty)
      return nil unless fail_qty.positive?

      Inventory::Inspect.call(lot: task.lot, work_order: order, pass_qty: 0, fail_qty: fail_qty, idempotency_key: "task:#{task.id}")
                        .first.stock_move
    end

    # 합격 적치(ref = 검사 작업, 그 ref = 작업지시)가 끝나면 검사 기록(pass)을 이동에 붙인다.
    def record_pass(task, move)
      inspected = Task.find_by(id: task.ref_id) if task.ref_type == "Task"
      order = WorkOrder.find_by(id: inspected.ref_id) if inspected&.ref_type == "WorkOrder"
      return unless order && task.lot

      Inspection.find_or_create_by!(stock_move_id: move.id) do |i|
        i.lot = task.lot
        i.work_order = order
        i.result = "pass"
        i.defect_qty = 0
      end
    end
  end
end
