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
    ActiveRecord::Base.connection.execute(
      "TRUNCATE machine_state_events, production_events, commands, work_orders, machines RESTART IDENTITY CASCADE"
    )
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
      # 쿼리 캐시가 켜져 있으면 첫 결과(B 대기 전)를 계속 돌려주므로 캐시를 우회한다.
      query = ActiveRecord::Base.uncached { ActiveRecord::Base.connection.select_value(sql) }
      return query if query

      sleep 0.02
    end
    nil
  end

  # 스레드 A 는 명령을 처리한 뒤 커밋하지 않고 잠금을 쥔다. 그 사이 스레드 B 가 같은 기계를 요청한다.
  # B 는 별도 커넥션에서 version 을 읽기 전에 대기하다가 A 가 커밋한 뒤 409 를 받아야 한다.
  # B 는 키가 달라 advisory lock(같은 키 직렬화용)에는 걸리지 않고, 기계 행 잠금에서 대기한다.
  # 잠금이 없으면 B 는 stale version 을 읽고 UPDATE "machines" 에서 대기한다. 구분 기준은 대기 SQL 이다.
  test "A 가 잠금을 쥔 동안 B 는 version 을 읽기 전에 대기하고 A 커밋 뒤 409 를 받는다" do
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
      # advisory lock 대기라면 SQL 이 pg_advisory_xact_lock 이므로 아래 단언에서 실패한다(키가 같다는 뜻).
      # 잠금이 있으면 B 는 version 을 읽기 전에 대기한다. 보통 commands INSERT 의 FK 검사(FOR KEY SHARE)가
      # A 가 쥔 machines FOR UPDATE 와 충돌해 INSERT 에서 멈추므로 대기 SQL 은 INSERT 이거나 FOR UPDATE 다.
      assert_no_match(/UPDATE\s+"machines"/i, query, "B 가 stale version 을 읽고 UPDATE 에서 대기 — 잠금 없음")
      assert_match(/FOR UPDATE|INSERT INTO "commands"/i, query, "B 는 version 을 읽기 전에 대기해야 한다")
      assert thread_b.alive?, "B 는 A 커밋 전에 끝나면 안 된다"
      assert_equal ["running", 0], [@machine.reload.state, @machine.version], "A 는 아직 커밋하지 않았다"
    ensure
      release_a << true
      threads.each do |t|
        t.join(15)
      rescue StandardError
        nil # 본 단언 실패를 가리지 않는다
      end
    end

    results = threads.map { |t| t.join(15) ? t.value : flunk("스레드가 15초 안에 끝나지 않았다") }

    assert_equal [200, 409], results.map(&:status)
    assert_equal ["stopped", 1], [@machine.reload.state, @machine.version]
    assert_equal 1, MachineStateEvent.where(machine: @machine).count
  end
end
