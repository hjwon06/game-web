require "test_helper"

# 같은 기계에 서로 다른 키로 동시에 온 명령이 교착 없이 {200, 409} 로 끝나야 한다.
# MachineCommand 가 commands INSERT 를 machines FOR UPDATE 보다 먼저 하면(FK KEY SHARE 선점)
# 두 요청이 서로의 FOR UPDATE 를 기다려 ActiveRecord::Deadlocked 가 난다.
class ConcurrencyDeadlockTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  ROUNDS = 20
  JOIN_SECONDS = 15

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

  def reset_machine
    # version 을 0 으로 되돌리면 이전 라운드의 (machine_id, version) 이벤트가 남아 다음 라운드 첫 전이와 UniqueViolation 이 나므로 함께 지운다.
    MachineStateEvent.where(machine_id: @machine.id).delete_all
    Machine.where(id: @machine.id).update_all(state: "running", version: 0)
  end

  # 스레드는 라운드마다 inbox 에서 키를 받고, start 큐에서 출발 신호를 받아 명령을 실행한 뒤 결과를 results 에 넣는다.
  def worker(inbox, start, results)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        while (key = inbox.pop)
          start.pop
          outcome =
            begin
              MachineCommand.call(idempotency_key: key, machine_code: "M1", kind: "stop", base_version: 0).status
            rescue StandardError => e
              e
            end
          results << outcome
        end
      end
    end
  end

  test "같은 기계·다른 키 동시 명령 20회가 교착 없이 200 과 409 로 끝난다" do
    inboxes = Array.new(2) { Queue.new }
    start = Queue.new
    results = Queue.new
    threads = inboxes.map { |inbox| worker(inbox, start, results) }
    threads.each { |t| t.report_on_exception = false }
    errors = []
    rounds = []

    begin
      ROUNDS.times do
        reset_machine
        inboxes.each { |inbox| inbox << SecureRandom.uuid }
        2.times { start << true } # 두 스레드가 키를 받아 start 에서 대기한 뒤 거의 동시에 출발한다
        outcomes = Array.new(2) { results.pop(timeout: JOIN_SECONDS) || flunk("명령이 #{JOIN_SECONDS}초 안에 끝나지 않았다") }
        errors.concat(outcomes.grep(Exception))
        rounds << outcomes.reject { |o| o.is_a?(Exception) }.sort
      end
    ensure
      inboxes.each { |inbox| inbox << nil }
      threads.each do |t|
        t.join(JOIN_SECONDS)
      rescue StandardError
        nil # 본 단언 실패를 가리지 않는다
      end
    end

    assert_empty errors.map { |e| "#{e.class}: #{e.message.lines.first}" }, "예외(교착 포함)가 없어야 한다"
    assert_equal ROUNDS, rounds.size
    assert(rounds.all? { |r| r == [200, 409] }, "매 회 {200, 409} 여야 한다: #{rounds.tally}")
    assert_equal ["stopped", 1], [@machine.reload.state, @machine.version]
  end
end
