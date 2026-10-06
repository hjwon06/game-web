require "test_helper"

# 트랜잭션 테스트를 끄고 스레드마다 별도 커넥션으로 실제 잠금 경합을 만든다.
# MachineCommand 의 FOR UPDATE 를 지우면 이 테스트는 실패해야 한다.
class ConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  HOLD_SECONDS = 0.6

  setup do
    wipe
    @machine = Machine.create!(code: "M1", name: "절단기", state: "running")
  end

  teardown { wipe }

  def wipe
    [MachineStateEvent, Command, ProductionEvent, WorkOrder, Machine].each(&:delete_all)
  end

  def stop(base_version)
    MachineCommand.call(idempotency_key: SecureRandom.uuid, machine_code: "M1", kind: "stop",
                        base_version: base_version)
  end

  def backend_pid
    ActiveRecord::Base.connection_pool.with_connection { |c| c.select_value("SELECT pg_backend_pid()") }
  end

  # 스레드 A 는 명령을 처리한 뒤 커밋하지 않고 잠금을 쥔다. 그 사이 스레드 B 가 같은 기계를 요청한다.
  # 잠금이 있으면 B 는 A 의 커밋을 기다렸다가 새 version 을 보고 409 를 받는다.
  # 잠금이 없으면 B 는 낡은 version 으로 통과해 200 이 되거나 이벤트 유일 인덱스에서 예외가 난다.
  test "같은 base_version 으로 stop 두 건을 동시에 보내면 하나는 200 하나는 409 다" do
    a_has_lock = Queue.new
    pids = Queue.new

    thread_a = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        pids << backend_pid
        Machine.transaction do
          result = stop(0)
          a_has_lock << true
          sleep HOLD_SECONDS
          result
        end
      end
    end
    thread_b = Thread.new do
      a_has_lock.pop
      ActiveRecord::Base.connection_pool.with_connection do
        pids << backend_pid
        stop(0)
      end
    end
    [thread_a, thread_b].each { |t| t.report_on_exception = false }

    results = [thread_a, thread_b].map { |t| t.join(15) ? t.value : flunk("스레드가 15초 안에 끝나지 않았다") }

    assert_equal [200, 409], results.map(&:status).sort
    assert_equal 2, pids.size.times.map { pids.pop }.uniq.size, "두 스레드는 서로 다른 DB 커넥션이어야 한다"
    assert_equal ["stopped", 1], [@machine.reload.state, @machine.version]
    assert_equal 1, MachineStateEvent.where(machine: @machine).count
  end
end
