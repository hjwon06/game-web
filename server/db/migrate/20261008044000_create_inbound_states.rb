# 입고 트럭 스케줄 상태: 다음 트럭 도착 시각을 DB 1행에 둬서 재시작해도 트럭이 중복되거나 사라지지 않게 한다.
# singleton 컬럼의 유니크 + CHECK 가 "행은 최대 1개"를 DB 에서 보장한다.
class CreateInboundStates < ActiveRecord::Migration[8.1]
  def change
    create_table :inbound_states do |t|
      t.boolean :singleton, null: false, default: true
      t.datetime :next_truck_at, null: false
      t.timestamps

      t.index :singleton, unique: true
      t.check_constraint "singleton", name: "inbound_states_singleton_check"
    end
  end
end
