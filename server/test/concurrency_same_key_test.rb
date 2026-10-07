require "test_helper"

# 같은 키 동시 요청: A(있는 기계)가 커밋하기 전에 B(없는 기계)가 같은 키로 오면 B 는 404 가 아니라 422 여야 한다.
# MachineCommand 의 advisory lock 줄을 지우면 B 가 잠금 대기 없이 404 를 받아 이 테스트는 실패해야 한다.
class ConcurrencySameKeyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  WAIT_SECONDS = 5

  setup do
    wipe
    @machine = Machine.create!(code: "M1", name: "절단기", state: "running")
    @key = SecureRandom.uuid
  end

  teardown { wipe }

  def wipe
    ActiveRecord::Base.connection.execute(
      "TRUNCATE machine_state_events, production_events, commands, work_orders, machines RESTART IDENTITY CASCADE"
    )
  end

  def backend_pid
    ActiveRecord::Base.connection_pool.with_connection { |c| c.select_value("SELECT pg_backend_pid()") }
  end

  def command(code)
    MachineCommand.call(idempotency_key: @key, machine_code: code, kind: "stop", base_version: 0)
  end

  # 해당 백엔드가 잠금 대기 중이면 그때 실행 중인 SQL 을 돌려준다. 끝내 대기하지 않으면 nil.
  def blocked_query(pid)
    sql = ActiveRecord::Base.sanitize_sql(
      ["SELECT query FROM pg_stat_activity WHERE pid = ? AND wait_event_type = 'Lock'", pid]
    )
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WAIT_SECONDS
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      query = ActiveRecord::Base.uncached { ActiveRecord::Base.connection.select_value(sql) }
      return query if query

      sleep 0.02
    end
    nil
  end

  test "같은 키로 A(있는 기계)가 커밋하기 전에 온 B(없는 기계)는 대기했다가 422 를 받는다" do
    a_done = Queue.new
    release_a = Queue.new
    pid_b = Queue.new

    thread_a = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Machine.transaction do
          result = command("M1")
          a_done << true
          release_a.pop(timeout: 15)
          result
        end
      end
    end
    thread_b = Thread.new do
      a_done.pop(timeout: WAIT_SECONDS) || raise("A 가 명령을 처리하지 못했다")
      ActiveRecord::Base.connection_pool.with_connection do
        pid_b << backend_pid
        command("NOPE")
      end
    end
    threads = [thread_a, thread_b]
    threads.each { |t| t.report_on_exception = false }

    begin
      b_pid = pid_b.pop(timeout: WAIT_SECONDS) || flunk("B 가 시작하지 않았다")
      query = blocked_query(b_pid)
      assert_not_nil query, "B 가 같은 키 잠금에서 대기하지 않았다 — 직렬화 없음"
      assert_match(/pg_advisory_xact_lock/i, query, "B 는 advisory lock 에서 대기해야 한다")
      assert thread_b.alive?, "B 는 A 커밋 전에 끝나면 안 된다"
    ensure
      release_a << true
      threads.each do |t|
        t.join(15)
      rescue StandardError
        nil # 본 단언 실패를 가리지 않는다
      end
    end

    results = threads.map { |t| t.join(15) ? t.value : flunk("스레드가 15초 안에 끝나지 않았다") }

    assert_equal [200, 422], results.map(&:status), "같은 키·다른 내용은 404 가 아니라 422"
    assert_nil results.last.machine
    assert_equal 1, Command.where(idempotency_key: @key).count
  end
end
