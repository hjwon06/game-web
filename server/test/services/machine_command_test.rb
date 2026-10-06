require "test_helper"

class MachineCommandTest < ActiveSupport::TestCase
  setup do
    @m1 = Machine.create!(code: "M1", name: "절단기", state: "running")
    @m2 = Machine.create!(code: "M2", name: "조립기", state: "stopped")
    @m3 = Machine.create!(code: "M3", name: "검사기", state: "broken")
  end

  def run_command(machine, kind, base_version: nil, key: SecureRandom.uuid)
    MachineCommand.call(idempotency_key: key, machine_code: machine.code, kind: kind,
                        base_version: base_version || machine.reload.version)
  end

  test "정상 전이 4종이 상태와 version 과 이벤트를 남긴다" do
    [[@m2, "start", "running"], [@m2, "stop", "stopped"],
     [@m2, "break", "broken"], [@m2, "repair", "stopped"]].each_with_index do |(machine, kind, to), i|
      result = run_command(machine, kind)
      assert_equal 200, result.status, kind
      assert_equal to, result.machine.state, kind
      assert_equal i + 1, machine.reload.version, kind
    end
    assert_equal [1, 2, 3, 4], MachineStateEvent.where(machine: @m2).order(:version).pluck(:version)
    assert_equal %w[stopped running stopped broken], MachineStateEvent.where(machine: @m2).order(:version).pluck(:from_state)
    assert_equal 4, MachineStateEvent.where(machine: @m2).where.not(command_id: nil).count
  end

  test "같은 키 재요청은 같은 결과를 주고 행은 1개다" do
    key = SecureRandom.uuid
    first = run_command(@m2, "start", key: key)
    again = run_command(@m2, "start", base_version: 0, key: key)

    assert_equal [200, 200], [first.status, again.status]
    assert_equal first.machine.version, again.machine.version
    assert_equal 1, Command.where(idempotency_key: key).count
    assert_equal 1, @m2.reload.version
    assert_equal 1, MachineStateEvent.where(machine: @m2).count
  end

  test "base_version 불일치는 409 이고 재시도도 409 다" do
    key = SecureRandom.uuid
    first = run_command(@m1, "stop", base_version: 5, key: key)
    again = run_command(@m1, "stop", base_version: @m1.version, key: key)

    assert_equal [409, 409], [first.status, again.status]
    assert_equal 409, Command.find_by!(idempotency_key: key).result_status
    assert_equal ["running", 0], [@m1.reload.state, @m1.version]
    assert_equal 0, MachineStateEvent.count
  end

  test "이미 목표 상태면 200 no-op 이고 version 은 그대로다" do
    result = run_command(@m1, "start")

    assert_equal 200, result.status
    assert_equal 0, @m1.reload.version
    assert_equal 0, MachineStateEvent.count
    assert_equal 200, Command.last.result_status
  end

  test "불가 전이는 422 로 기록된다" do
    key = SecureRandom.uuid
    result = run_command(@m3, "start", key: key)
    again = run_command(@m3, "start", key: key)

    assert_equal [422, 422], [result.status, again.status]
    assert_equal 422, Command.find_by!(idempotency_key: key).result_status
    assert_equal ["broken", 0], [@m3.reload.state, @m3.version]
  end

  test "없는 기계는 404 이고 commands 행을 쓰지 않는다" do
    result = MachineCommand.call(idempotency_key: SecureRandom.uuid, machine_code: "M9",
                                 kind: "start", base_version: 0)

    assert_equal 404, result.status
    assert_nil result.machine
    assert_equal 0, Command.count
  end

  test "형식이 틀린 입력은 422 이고 commands 행을 쓰지 않는다" do
    bad = [["not-a-uuid", "start", 0], [SecureRandom.uuid, "explode", 0], [SecureRandom.uuid, "start", "x"]]
    bad.each do |key, kind, version|
      result = MachineCommand.call(idempotency_key: key, machine_code: "M1", kind: kind, base_version: version)
      assert_equal 422, result.status
    end
    assert_equal 0, Command.count
  end
end
