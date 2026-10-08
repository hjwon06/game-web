module Simulation
  # 기계가 놀지 않게 작업지시를 보충한다. 작업지시는 시드로만 생기므로 끝난 기계가 하나씩 선다.
  #   - Flusher: 작업지시가 끝난 같은 트랜잭션에서 queued 가 없으면 다음 작업지시를 만든다(after_done).
  #   - Runner 기동 시 1회 + Logistics 매분: running 인데 active 가 없는 기계를 채운다(sweep).
  # 새 작업지시 = 같은 품목, target_qty = Config.rate x (1 - 불량률) x 3600(1시간 분량)을 100 단위로 반올림, code 는 WO-NNNN 다음 번호, status active.
  # stopped·broken 기계는 보충하지 않는다. Flusher 와 Logistics 는 같은 프로세스(bin/sim)에서 차례로 돌아 번호가 겹치지 않는다.
  module WorkOrderRefill
    CODE_PREFIX = "WO-".freeze
    QTY_UNIT = 100
    HORIZON_SECONDS = 3600

    module_function

    # 끝난 작업지시의 기계에 queued 를 올리거나(있으면) 새로 만든다. Flusher 트랜잭션 안에서 부른다.
    def after_done(done_order, logger: Rails.logger)
      machine = done_order.machine
      queued = WorkOrder.where(machine_id: machine.id, status: "queued").order(:created_at, :id).lock.first
      return queued.update!(status: "active", started_at: Time.current) if queued

      create_next(machine, done_order, logger: logger)
    end

    # running 인데 active 가 없는 기계를 채운다. 반환: 올리거나 만든 작업지시 수.
    def sweep(logger: Rails.logger)
      filled = 0
      Machine.where(state: "running").order(:id).each do |machine|
        filled += 1 if refill_idle(machine, logger: logger)
      end
      filled
    end

    def refill_idle(machine, logger:)
      ApplicationRecord.transaction(requires_new: true) do
        machine.lock!
        next false if WorkOrder.where(machine_id: machine.id, status: "active").exists?

        queued = WorkOrder.where(machine_id: machine.id, status: "queued").order(:created_at, :id).lock.first
        if queued
          queued.update!(status: "active", started_at: Time.current)
          logger.info("sim refill #{machine.code} queued #{queued.code} 활성화")
          next true
        end

        last = WorkOrder.where(machine_id: machine.id).order(:created_at, :id).last
        unless last
          logger.info("sim refill #{machine.code} 작업지시 이력이 없어 건너뜀")
          next false
        end
        create_next(machine, last, logger: logger).present?
      end
    end

    def create_next(machine, previous, logger:)
      code = next_code
      order = ApplicationRecord.transaction(requires_new: true) do
        WorkOrder.create!(code: code, machine: machine, item: previous.item, product: previous.product,
                          target_qty: target_qty(machine.code), status: "active", started_at: Time.current)
      end
      logger.info("sim refill #{machine.code} 새 작업지시 #{order.code} #{order.product} 목표 #{order.target_qty}")
      order
    rescue ActiveRecord::RecordNotUnique
      logger.warn("sim refill #{machine.code} 작업지시 #{code} 가 겹쳐 이번에는 만들지 않음")
      nil
    end

    def target_qty(machine_code)
      hourly = Config.rate(machine_code) * (1 - Config.defect_rate(machine_code)) * HORIZON_SECONDS
      [(hourly / QTY_UNIT).round * QTY_UNIT, QTY_UNIT].max
    end

    # WO-NNNN 형식(숫자만)의 마지막 번호 + 1. WO-P0001 같은 다른 접두 형식은 무시한다.
    def next_code
      last = WorkOrder.where("code ~ '^WO-[0-9]+$'").pick(Arel.sql("MAX(substring(code from 4)::bigint)")) || 0
      format("%s%04d", CODE_PREFIX, last + 1)
    end
  end
end
