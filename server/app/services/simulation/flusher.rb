module Simulation
  # 10초 경계에서 누적기를 DB 에 한 트랜잭션으로 기록한다. machines.state 는 읽기만 한다.
  class Flusher
    def self.call(accumulator, bucket_start)
      new(accumulator, bucket_start).call
    end

    def initialize(accumulator, bucket_start)
      @accumulator = accumulator
      @bucket_start = bucket_start
      @bucket_end = bucket_start + Config::BUCKET_SECONDS
    end

    # 실제로 들어간 production_events 행 수를 돌려준다.
    def call
      inserted = ApplicationRecord.transaction do
        Machine.order(:id).lock.to_a.count { |machine| flush_machine(machine) } # ①
      end
      @accumulator.reset! # ⑦ 커밋 이후
      inserted
    end

    private

    def flush_machine(machine)
      entry = @accumulator.entry(machine.code)
      return false unless writable?(machine, entry) # ②

      order = WorkOrder.where(machine_id: machine.id, status: "active").lock.first
      return false unless order # ③

      return false unless insert_event(machine, order, entry) # ④

      advance(order, entry.good_qty) # ⑤⑥
      true
    end

    def writable?(machine, entry)
      entry && !entry.discarded && machine.state == "running" && machine.version == entry.version
    end

    # 충돌하면 빈 결과가 돌아온다. 행 수로 실제 삽입 여부를 판단한다.
    def insert_event(machine, order, entry)
      row = { machine_id: machine.id, work_order_id: order.id, bucket_start: @bucket_start,
              bucket_end: @bucket_end, good_qty: entry.good_qty, defect_qty: entry.defect_qty,
              machine_version: entry.version }
      ProductionEvent.insert(row, unique_by: %i[machine_id bucket_start], returning: %w[id]).rows.any?
    end

    # ⑤ 1행이 들어간 경우에만 호출된다.
    def advance(order, good_qty)
      order.produced_qty += good_qty
      return order.save! if order.produced_qty < order.target_qty

      order.update!(produced_qty: order.produced_qty, status: "done", finished_at: Time.current) # ⑥
      activate_next(order.machine_id)
    end

    def activate_next(machine_id)
      queued = WorkOrder.where(machine_id: machine_id, status: "queued").order(:created_at, :id).lock.first
      queued&.update!(status: "active", started_at: Time.current)
    end
  end
end
