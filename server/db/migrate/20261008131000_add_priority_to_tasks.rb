# 지게차 큐 우선순위(2단계-⑥j): 작을수록 먼저. Ops::Plan 이 종류별 기본값(feed 10, 원자재 적치 30, 완제품 적치 40, 나머지 50)을 넣고,
# 덜 급한(값이 큰) planned 작업 앞에 끼워 넣는다. 이미 쌓인 행은 기본값 50 이라 기존 FIFO 순서와 같다.
class AddPriorityToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :priority, :integer, null: false, default: 50
  end
end
