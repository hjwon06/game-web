# 이벤트 큐 코어(2단계-②): 작업은 계획 때 예상 완료 시각을 갖고, 실패로 취소되면 사유를 남긴다.
# expected_finish_at 은 자원의 next_free 계산(마지막 planned/started 작업의 예상 완료)과 Tick 의 완료 판정이 읽는다.
# 이미 쌓인 행은 없으므로 NULL 허용으로 둔다(수동으로 만든 행·취소 행이 값 없이 있어도 된다).
class AddFinishAndCancelToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :expected_finish_at, :datetime
    add_column :tasks, :cancel_reason, :text
  end
end
