# 시뮬레이션 기준 시각을 지금으로 옮긴다. 밀린 생산(미소비분)은 버리고 새로 시작한다. bin/sim 은 재시작하지 않아도 다음 분부터 읽는다.
# INVENTORY_EPOCH 환경변수가 있으면 그 값이 이기므로 rebase 가 효과가 없다 — 경고하고 끝낸다.
namespace :sim do
  desc "시뮬레이션 epoch 를 지금으로 옮긴다(밀린 생산을 버리고 새로 시작)"
  task rebase: :environment do
    if ENV["INVENTORY_EPOCH"].present?
      warn "INVENTORY_EPOCH=#{ENV['INVENTORY_EPOCH']} 가 설정돼 있어 rebase 가 적용되지 않는다. 환경변수를 지우고 다시 실행하라."
      next
    end

    ReorderRule.ensure_defaults!
    epoch = SimEpoch.rebase!
    puts "sim epoch = #{epoch.started_at.utc.iso8601}"
  end
end
