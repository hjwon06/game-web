require "test_helper"

class MachineTest < ActiveSupport::TestCase
  def insert_machine(code:, state:)
    Machine.transaction(requires_new: true) do
      Machine.insert_all!([{ code: code, name: "x", state: state, created_at: Time.current, updated_at: Time.current }])
    end
  end

  test "잘못된 state 는 DB CHECK 제약이 막는다" do
    assert_raises(ActiveRecord::CheckViolation) { insert_machine(code: "MX", state: "exploded") }
  end

  test "올바른 state 는 DB 에 들어간다" do
    assert_difference("Machine.count", 1) { insert_machine(code: "MY", state: "broken") }
  end

  test "code 중복은 DB UNIQUE 가 막는다" do
    insert_machine(code: "MZ", state: "stopped")
    assert_raises(ActiveRecord::RecordNotUnique) { insert_machine(code: "MZ", state: "stopped") }
  end

  test "모델 검증도 잘못된 state 를 거절한다" do
    refute Machine.new(code: "MV", name: "x", state: "exploded").valid?
  end
end
