namespace :securities do
  desc "증권 가상 시드(자산 6 · 계좌 203 · 개시 원장 · 거래일 30). SEED=42, 재실행 안전"
  task seed: :environment do
    Securities::Seed.run!(seed: ENV.fetch("SEED", Securities::Seed::DEFAULT_SEED).to_i)
    puts "securities:seed " + Securities::Seed.counts.map { |table, n| "#{table} #{n}" }.join(" / ")
  end
end
