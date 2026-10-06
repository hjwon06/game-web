require "test_helper"

class MachineStateEventTest < ActiveSupport::TestCase
  setup { @machine = Machine.create!(code: "M1", name: "절단기") }

  def insert_event(version)
    MachineStateEvent.transaction(requires_new: true) do
      MachineStateEvent.insert_all!([{ machine_id: @machine.id, from_state: "stopped", to_state: "running",
                                       version: version, at: Time.current }])
    end
  end

  test "같은 (machine_id, version) 은 DB UNIQUE 가 막는다" do
    insert_event(1)
    assert_raises(ActiveRecord::RecordNotUnique) { insert_event(1) }
  end

  test "다른 version 은 들어간다" do
    insert_event(1)
    assert_difference("MachineStateEvent.count", 1) { insert_event(2) }
  end
end
