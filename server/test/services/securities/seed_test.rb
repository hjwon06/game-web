require "test_helper"
require "rake"

Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

class Securities::SeedTest < ActiveSupport::TestCase
  TABLES = %w[assets accounts positions holds orders executions settlements ledger_entries market_days].freeze

  def snapshot
    TABLES.to_h { |t| [t, Securities::Record.lease_connection.select_value("SELECT count(*) FROM #{t}").to_i] }
  end

  test "계좌 203 · 자산 6, 이름과 코드는 가상이다" do
    Securities::Seed.run!(seed: 42)

    assert_equal 203, Securities::Account.count
    assert_equal({ "investor" => 200, "broker" => 1, "clearing" => 1, "depository" => 1 },
                 Securities::Account.group(:kind).count)
    assert_equal 6, Securities::Asset.count
    assert_equal 1, Securities::Asset.where(kind: "cash").count
    assert_equal({ "VELEC" => 72_000, "VBIO" => 260_000, "VBANK" => 18_000, "VCONS" => 3_000, "VGAME" => 610_000 },
                 Securities::Asset.where(kind: "equity").pluck(:code, :base_price).to_h)
    assert Securities::Asset.pluck(:code).all? { |c| c.start_with?("V") }
    assert Securities::Account.pluck(:code).all? { |c| c.start_with?("V") }
    assert Securities::Asset.where(kind: "equity").pluck(:name).all? { |n| n.start_with?("가상") }
  end

  test "예탁을 뺀 계좌에서 원장 합계 = positions, 예탁은 positions 행이 없다" do
    Securities::Seed.run!(seed: 42)
    depository = Securities::Account.find_by!(kind: "depository")

    net = Hash.new(0)
    Securities::LedgerEntry.find_each do |e|
      net[[e.to_account_id, e.asset_id]] += e.qty
      net[[e.from_account_id, e.asset_id]] -= e.qty
    end
    outside = net.reject { |(account_id, _), qty| account_id == depository.id || qty.zero? }
    positions = Securities::Position.all.to_h { |p| [[p.account_id, p.asset_id], p.qty] }

    assert_operator positions.size, :>, 200 # 투자자 200 의 현금 + 종목 보유
    assert_equal positions, outside
    assert_equal 0, Securities::Position.where(account_id: depository.id).count
    assert_equal Securities::Position.sum(:qty), -net.select { |(account_id, _), _| account_id == depository.id }.values.sum
  end

  test "원장은 전부 개시 settlement(2026-10-30, settled)에 묶이고 현금은 1천만~1억이다" do
    Securities::Seed.run!(seed: 42)

    settlement = Securities::Settlement.sole
    assert_equal Date.new(2026, 10, 30), settlement.settle_date
    assert_equal "settled", settlement.status
    assert_equal [settlement.id], Securities::LedgerEntry.distinct.pluck(:settlement_id)

    cash = Securities::Asset.find_by!(code: Securities::Asset::CASH_CODE)
    amounts = Securities::Position.where(asset_id: cash.id).pluck(:qty)
    assert_equal 200, amounts.size
    assert amounts.all? { |q| q.between?(10_000_000, 100_000_000) }
    held = Securities::Position.where.not(asset_id: cash.id).group(:account_id).count.values
    assert held.all? { |n| n <= 3 }
  end

  test "거래일 30일은 2026-11-02 부터이고 토 · 일만 휴장이다" do
    Securities::Seed.run!(seed: 42)
    days = Securities::MarketDay.order(:trade_date).to_a

    assert_equal 30, days.size
    assert_equal Date.new(2026, 11, 2), days.first.trade_date
    assert_equal Date.new(2026, 12, 1), days.last.trade_date
    assert_equal(days.map { |d| d.trade_date.saturday? || d.trade_date.sunday? }, days.map { |d| !d.business_day })
    assert_operator days.count { |d| !d.business_day }, :>, 0
  end

  test "plan 은 같은 seed 면 같고 다른 seed 면 다르며 DB 를 쓰지 않는다" do
    before = snapshot

    assert_equal Securities::Seed.plan(seed: 42), Securities::Seed.plan(seed: 42)
    refute_equal Securities::Seed.plan(seed: 42), Securities::Seed.plan(seed: 43)
    assert_equal before, snapshot
  end

  test "run! 을 다시 돌려도 행 수가 그대로다" do
    Securities::Seed.run!(seed: 42)
    once = snapshot
    assert_operator once["ledger_entries"], :>, 200

    Securities::Seed.run!(seed: 42)
    assert_equal once, snapshot
  end

  test "다른 seed 로 채운 DB 에 run! 하면 예외이고 아무것도 쓰지 않는다" do
    Securities::Seed.run!(seed: 42)
    before = snapshot
    positions = Securities::Position.order(:id).pluck(:account_id, :asset_id, :qty)

    assert_raises(Securities::Seed::Mismatch) { Securities::Seed.run!(seed: 43) }

    assert_equal before, snapshot
    assert_equal positions, Securities::Position.order(:id).pluck(:account_id, :asset_id, :qty)
  end

  test "비어 있지 않은데 positions 가 plan 과 다르면(일부만 있는 DB) 예외다" do
    Securities::Seed.run!(seed: 42)
    Securities::Position.where(id: Securities::Position.minimum(:id)).delete_all
    before = snapshot

    assert_raises(Securities::Seed::Mismatch) { Securities::Seed.run!(seed: 42) }
    assert_equal before, snapshot
  end

  # rake 를 직접 불러온다 — 증권 테스트만 돌려도 태스크가 있어야 한다.
  def invoke_seed_task(seed: nil)
    Rails.application.load_tasks unless Rake::Task.task_defined?("securities:seed")
    task = Rake::Task["securities:seed"]
    task.reenable
    old = ENV["SEED"]
    seed.nil? ? ENV.delete("SEED") : ENV["SEED"] = seed
    capture_io { task.invoke }.first
  ensure
    old.nil? ? ENV.delete("SEED") : ENV["SEED"] = old
  end

  test "securities:seed rake 가 Seed.run! 을 부른다" do
    out = invoke_seed_task

    assert_equal 203, Securities::Account.count
    assert_match(/securities:seed .*accounts 203/, out)
  end

  test "securities:seed 의 SEED 가 숫자가 아니면 예외이고 아무것도 쓰지 않는다" do
    before = snapshot

    assert_raises(ArgumentError) { invoke_seed_task(seed: "abc") }
    assert_raises(ArgumentError) { invoke_seed_task(seed: "42abc") }
    assert_equal before, snapshot
  end
end
