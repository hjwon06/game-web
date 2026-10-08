namespace :task do
  desc "끝난 지 7일 지난 done/cancelled 작업 삭제(TASK_KEEP_DAYS 로 조정). stock_moves 는 지우지 않는다"
  task prune: :environment do
    days = Integer(ENV.fetch("TASK_KEEP_DAYS", Task::RETENTION.in_days.to_i))
    puts "task:prune #{Task.prune!(before: days.days.ago)}건 삭제 (보존 #{days}일)"
  end
end
