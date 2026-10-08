# 자재 대기 표시. 기계 state(running/stopped/broken, 사용자 명령 대상)와 별개다.
# 값이 있으면 "running 인데 라인사이드 자재가 다음 60초 생산분에 모자라 생산이 서 있다"는 뜻이고, 값은 그 상태가 시작된 시각이다.
class AddMaterialShortSinceToMachines < ActiveRecord::Migration[8.1]
  def change
    add_column :machines, :material_short_since, :timestamptz
  end
end
