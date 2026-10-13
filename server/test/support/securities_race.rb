# 증권 동시성 테스트 공용 도구. 트랜잭션 테스트를 끈 테스트 케이스에 include 한다(flunk · uncached 를 쓴다).
#
# 대기 판정: pg_stat_activity 의 wait_event_type · wait_event 는 지금 값이고 state · query 는 그 트랜잭션의 첫 조회 시점
# 스냅숏이다. BEGIN 직후 다음 문장에서 막히는 순간에는 "idle in transaction · BEGIN · Lock" 이 한 행에 나온다.
# 그래서 state = 'active' 이고 query 가 기대한 SQL 일 때만 "그 SQL 에서 대기"로 센다.
module SecuritiesRace
  WAIT_SECONDS = 5

  # 대기를 끝내 못 찾았을 때 단언 메시지에 쓰도록 마지막으로 본 값을 담는다.
  Seen = Struct.new(:found, :state, :wait_event, :query) do
    def to_s
      "state=#{state.inspect} wait_event=#{wait_event.inspect} query=#{query.inspect}"
    end
  end

  def backend_pid
    Securities::Record.connection_pool.with_connection { |c| c.select_value("SELECT pg_backend_pid()") }
  end

  # pid 가 Lock 대기 + active 이고 query 가 expect 와 맞는 행이 나올 때까지 WAIT_SECONDS 폴링한다.
  # found 가 true 면 그 행, 아니면 마지막으로 본 state · wait_event · query 를 돌려준다.
  def blocked_query(pid, expect:)
    sql = Securities::Record.sanitize_sql(
      ["SELECT state, wait_event_type, wait_event, query FROM pg_stat_activity WHERE pid = ?", pid]
    )
    seen = Seen.new(false, nil, nil, nil)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WAIT_SECONDS
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      # 쿼리 캐시가 켜져 있으면 B 대기 전 결과를 계속 돌려주므로 캐시를 우회한다.
      row = Securities::Record.uncached { Securities::Record.lease_connection.select_one(sql) }
      if row
        seen = Seen.new(false, row["state"], row["wait_event"], row["query"])
        if row["wait_event_type"] == "Lock" && row["state"] == "active" && row["query"].to_s.match?(expect)
          seen.found = true
          return seen
        end
      end
      sleep 0.02
    end
    seen
  end

  # a(바깥 트랜잭션, 끝난 뒤 커밋 전 대기)와 b 를 겹쳐 실행한다. a · b 는 인자 없는 callable 이다.
  # [b 가 대기한 Seen, b 가 그 사이 살아 있었는지, a 결과, b 결과]. b 의 예외는 b 가 스스로 값으로 바꿔 돌려준다.
  def race(a:, b:, expect:)
    a_done = Queue.new
    release_a = Queue.new
    pid_b = Queue.new

    thread_a = Thread.new do
      Securities::Record.connection_pool.with_connection do
        Securities::Record.transaction do
          result = a.call
          a_done << true
          release_a.pop(timeout: 15)
          result
        end
      end
    end
    thread_b = Thread.new do
      a_done.pop(timeout: WAIT_SECONDS) || raise("A 가 끝나지 못했다")
      Securities::Record.connection_pool.with_connection do
        pid_b << backend_pid
        b.call
      end
    end
    threads = [thread_a, thread_b]
    threads.each { |t| t.report_on_exception = false }

    begin
      b_pid = pid_b.pop(timeout: WAIT_SECONDS) || flunk("B 가 시작하지 않았다")
      waiting = blocked_query(b_pid, expect: expect)
      b_alive = thread_b.alive?
    ensure
      release_a << true
      threads.each do |t|
        t.join(15)
      rescue StandardError
        nil # 본 단언 실패를 가리지 않는다
      end
    end

    results = threads.map { |t| t.join(15) ? t.value : flunk("스레드가 15초 안에 끝나지 않았다") }
    [waiting, b_alive, *results]
  end

  # waiting 이 expect 에서 Lock 대기 중이었고 wait_event 가 events 중 하나인지 단언한다.
  def assert_blocked(waiting, events:, message:)
    assert waiting.found, "#{message} — 마지막으로 본 값: #{waiting}"
    assert_includes events, waiting.wait_event, "#{message} — wait_event 가 다르다: #{waiting}"
  end
end
