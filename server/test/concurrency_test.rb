require "test_helper"

# 트랜잭션 테스트를 끄고 스레드마다 별도 커넥션으로 실제 잠금 경합을 만든다.
# MachineCommand 의 FOR UPDATE 를 지우면 이 테스트는 "잠금 대기" 단언에서 실패해야 한다.
class ConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  WAIT_SECONDS = 5

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

  # 해당 백엔드가 잠금 대기 중이면 그 시점에 실행 중인 SQL 을 돌려준다. 끝내 대기하지 않으면 nil.
  def blocked_query(pid)
    sql = ActiveRecord::Base.sanitize_sql(
      ["SELECT query FROM pg_stat_activity WHERE pid = ? AND wait_event_type = 'Lock'", pid]
    )
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WAIT_SECONDS
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      query = ActiveRecord::Base.connection.select_value(sql)
      return query if query

      sleep 0.02
    end
    nil
  end

  # 스레드 A 는 명령을 처리한 뒤 커밋하지 않고 잠금을 쥔다. 그 사이 스레드 B 가 같은 기계를 요청한다.
  # B 는 별도 커넥션에서 SELECT ... FOR UPDATE 에 걸려 A 가 커밋할 때까지 끝나지 않아야 한다.
  # 잠금이 없으면 B 는 UPDATE 에서 막히거나 아예 통과하므로 대기 중인 SQL 이 FOR UPDATE 가 아니다.
  test "A 가 잠금을 쥔 동안 B 는 FOR UPDATE 에서 대기하고 A 커밋 뒤 409 를 받는다" do
    a_has_lock = Queue.new
    release_a = Queue.new
    pid_a = Queue.new
    pid_b = Queue.new

    thread_a = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        pid_a << backend_pid
        Machine.transaction do
          result = stop(0)
          a_has_lock << true
          release_a.pop(timeout: 15)
          result
        end
      end
    end
    thread_b = Thread.new do
      a_has_lock.pop(timeout: WAIT_SECONDS) || raise("A 가 잠금을 잡지 못했다")
      ActiveRecord::Base.connection_pool.with_connection do
        pid_b << backend_pid
        stop(0)
      end
    end
    threads = [thread_a, thread_b]
    threads.each { |t| t.report_on_exception = false }

    begin
      b_pid = pid_b.pop(timeout: WAIT_SECONDS) || flunk("B 가 시작하지 않았다")
      assert_not_equal pid_a.pop, b_pid, "두 스레드는 서로 다른 DB 커넥션이어야 한다"

      query = blocked_query(b_pid)
      assert_not_nil query, "B 가 잠금 대기에 들어가지 않았다 — 잠금이 없다"
      assert_match(/FOR UPDATE/i, query, "B 는 기계 행의 FOR UPDATE 에서 대기해야 한다")
      assert thread_b.alive?, "B 는 A 커밋 전에 끝나면 안 된다"
      assert_equal ["running", 0], [@machine.reload.state, @machine.version], "A 는 아직 커밋하지 않았다"
    ensure
      release_a << true
    end

    results = threads.map { |t| t.join(15) ? t.value : flunk("스레드가 15초 안에 끝나지 않았다") }

    assert_equal [200, 409], results.map(&:status)
    assert_equal ["stopped", 1], [@machine.reload.state, @machine.version]
    assert_equal 1, MachineStateEvent.where(machine: @machine).count
  end
end
