# 시뮬레이션 기준 시각 이력. 가장 최근 행이 현재 기준이다(Simulation::Config.inventory_epoch). rake sim:rebase 가 1행 추가한다.
class CreateSimEpochs < ActiveRecord::Migration[8.1]
  def change
    create_table :sim_epochs do |t|
      t.timestamptz :started_at, null: false
      t.timestamps

      t.index :started_at
    end
  end
end
