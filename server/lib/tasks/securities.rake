namespace :securities do
  desc "증권 가상 시드(자산 6 · 계좌 203 · 개시 원장 · 거래일 30). SEED=42(숫자가 아니면 예외), 재실행 안전"
  task seed: :environment do
    Securities::Seed.run!(seed: Integer(ENV.fetch("SEED", Securities::Seed::DEFAULT_SEED.to_s), 10))
    puts "securities:seed " + Securities::Seed.counts.map { |table, n| "#{table} #{n}" }.join(" / ")
  end
end
