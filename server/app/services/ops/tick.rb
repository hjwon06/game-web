module Ops
  # 시계를 now 로 옮긴다: 시작 시각이 된 planned 는 started, 예상 완료가 지난 started 는 done(재고 이동 1건).
  # 재실행해도 안전하다 — 이동의 멱등키가 "task:<id>" 이고, 이미 done 인 작업은 다시 건드리지 않는다.
  class Tick
    # pick(fg_store 칸 → 출하대 이동 경로 없음)과 inspect(qc_pass/qc_fail 분기)는 3단계에서 정한다.
    class NotImplemented < StandardError; end

    MOVE_TYPE = { "unload" => "receive", "putaway" => "putaway", "feed" => "issue", "load" => "ship" }.freeze
    UNMAPPED = %w[pick inspect].freeze
    # 이 오류들은 "그 작업이 안 되는 것"이라 작업만 취소한다. 그 밖의 오류(DB 장애, NotImplemented)는 숨기지 않고 올린다.
    TASK_FAILURES = [
      Inventory::InsufficientStock, Inventory::CapacityExceeded, Inventory::Move::InvalidPath,
      Inventory::IdempotencyConflict
    ].freeze

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
        loop do
          running = Task.where(resource_id: id, status: "started").order(:id).first
          if running
            break unless running.expected_finish_at && running.expected_finish_at <= @now

            finish(running)
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
      move_type = move_type_for(task)
      begin
        # 이동이 실패하면 savepoint 째로 되돌아가 원장·재고에 흔적이 없다.
        Task.transaction(requires_new: true) do
          move = Inventory::Move.call(
            product: task.product, lot: task.lot, from: task.from_location, to: task.to_location, qty: task.qty,
            move_type: move_type, ref: task, idempotency_key: "task:#{task.id}"
          )
          task.update!(status: "done", finished_at: finished_at, stock_move: move)
        end
        @result.done << task.id
      rescue *TASK_FAILURES => e
        task.update!(status: "cancelled", finished_at: finished_at, cancel_reason: "#{e.class.name.demodulize}: #{e.message}")
        @result.cancelled << task.id
      end
    end

    def move_type_for(task)
      raise NotImplemented, "#{task.kind} 작업의 재고 이동은 3단계에서 정한다 (task #{task.id})" if UNMAPPED.include?(task.kind)

      MOVE_TYPE.fetch(task.kind)
    end
  end
end
