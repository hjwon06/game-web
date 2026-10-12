# 증권 가상 시드. plan 은 DB 를 안 만지는 행 목록이고, run! 은 그 목록을 저장한다.
# 같은 seed = 같은 계획. 저장은 ON CONFLICT DO NOTHING 이라 두 번 돌려도 행이 늘지 않는다.
# DB 가 비어 있지 않으면 plan 의 positions(계좌코드 · 자산코드 · 수량)와 DB 가 같을 때만 진행한다.
# 다르면(다른 seed 로 채운 DB 등) 아무것도 쓰지 않고 Seed::Mismatch 를 올린다 — 두 seed 가 섞이지 않게.
#
# 개시 잔고는 원장으로 만든다: 예탁 → 투자자 항목이 개시 settlement(2026-10-30, settled)에 묶이고
# positions 는 그 합이다. 예탁은 출처라 positions 행이 없다.
module Securities
  module Seed
    DEFAULT_SEED = 42

    class Mismatch < StandardError; end

    OPEN_DATE = Date.new(2026, 10, 30)
    OPEN_SETTLED_AT = Time.utc(2026, 10, 30, 7, 0, 0) # 16:00 KST
    FIRST_MARKET_DAY = Date.new(2026, 11, 2)
    MARKET_DAYS = 30

    INVESTORS = 200
    CASH_MIN = 10_000_000
    CASH_MAX = 100_000_000
    CASH_STEP = 100_000
    MAX_HOLDINGS = 3
    MAX_HOLD_QTY = 100

    # [코드, 이름, 기준가(원)]. 전부 가상이다.
    EQUITIES = [
      ["VELEC", "가상전자", 72_000],
      ["VBIO", "가상바이오", 260_000],
      ["VBANK", "가상은행", 18_000],
      ["VCONS", "가상건설", 3_000],
      ["VGAME", "가상게임", 610_000]
    ].freeze

    BROKER_CODE = "VBRK-001".freeze
    CLEARING_CODE = "VCLR-001".freeze
    DEPOSITORY_CODE = "VDEP-001".freeze

    module_function

    # DB 를 읽거나 쓰지 않는다. 행은 id 대신 코드(code)로 서로를 가리킨다.
    def plan(seed: DEFAULT_SEED)
      rng = Random.new(seed)
      investors = investor_codes
      holdings = investors.to_h { |code| [code, draw_holdings(rng)] }

      {
        assets: assets,
        accounts: accounts(investors),
        settlement: { settle_date: OPEN_DATE, status: "settled", settled_at: OPEN_SETTLED_AT },
        positions: positions(holdings),
        ledger_entries: ledger_entries(holdings),
        market_days: market_days
      }
    end

    def run!(seed: DEFAULT_SEED)
      rows = plan(seed: seed)

      Record.transaction do
        # 확인과 쓰기 사이에 다른 run! 이 끼어들지 못하게 트랜잭션 단위 잠금을 건다.
        Record.lease_connection.execute("SELECT pg_advisory_xact_lock(hashtext('securities:seed'))")
        ensure_same_plan!(rows)

        Asset.insert_all(rows[:assets])
        Account.insert_all(rows[:accounts])
        Settlement.insert_all([rows[:settlement]])
        MarketDay.insert_all(rows[:market_days])

        asset_ids = Asset.pluck(:code, :id).to_h
        account_ids = Account.pluck(:code, :id).to_h
        settlement_id = Settlement.find_by!(settle_date: rows[:settlement][:settle_date]).id

        Position.insert_all(rows[:positions].map do |p|
          { account_id: account_ids.fetch(p[:account_code]), asset_id: asset_ids.fetch(p[:asset_code]), qty: p[:qty] }
        end)
        LedgerEntry.insert_all(rows[:ledger_entries].map do |e|
          { settlement_id: settlement_id, idem_key: e[:idem_key], qty: e[:qty],
            from_account_id: account_ids.fetch(e[:from_account_code]),
            to_account_id: account_ids.fetch(e[:to_account_code]),
            asset_id: asset_ids.fetch(e[:asset_code]) }
        end)
      end

      rows
    end

    # 비어 있는 DB 는 통과. 비어 있지 않으면 positions 가 plan 과 정확히 같아야 한다.
    def ensure_same_plan!(rows)
      return unless [Asset, Account, Position, LedgerEntry].any?(&:exists?)

      expected = rows[:positions].to_h { |p| [[p[:account_code], p[:asset_code]], p[:qty]] }
      actual = Position.joins(:account, :asset).pluck("accounts.code", "assets.code", "positions.qty")
                       .to_h { |account, asset, qty| [[account, asset], qty] }
      return if actual == expected

      raise Mismatch, "DB 의 positions(#{actual.size}행)가 이 seed 의 plan(#{expected.size}행)과 다르다. 아무것도 쓰지 않았다"
    end

    def counts
      [Asset, Account, Position, Hold, Order, Execution, Settlement, LedgerEntry, MarketDay].to_h do |model|
        [model.table_name, model.count]
      end
    end

    def investor_codes
      (1..INVESTORS).map { |n| format("VINV-%03d", n) }
    end

    def assets
      [{ code: Asset::CASH_CODE, name: "가상원화", kind: "cash", base_price: nil }] +
        EQUITIES.map { |code, name, price| { code: code, name: name, kind: "equity", base_price: price } }
    end

    def accounts(investors)
      investors.map { |code| { code: code, name: "가상투자자 #{code.delete_prefix('VINV-')}", kind: "investor" } } + [
        { code: BROKER_CODE, name: "가상증권사", kind: "broker" },
        { code: CLEARING_CODE, name: "가상청산소", kind: "clearing" },
        { code: DEPOSITORY_CODE, name: "가상예탁원", kind: "depository" }
      ]
    end

    # 투자자 1명: { cash: 원, stocks: [[종목코드, 수량], ...] }. 추첨 순서가 고정이라 seed 가 같으면 결과가 같다.
    def draw_holdings(rng)
      cash = CASH_MIN + (rng.rand(0..((CASH_MAX - CASH_MIN) / CASH_STEP)) * CASH_STEP)
      codes = EQUITIES.map(&:first)
      picked = codes.sample(rng.rand(0..MAX_HOLDINGS), random: rng).sort_by { |c| codes.index(c) }
      { cash: cash, stocks: picked.map { |code| [code, rng.rand(1..MAX_HOLD_QTY)] } }
    end

    # [계좌코드, 자산코드, 수량] 로 펼친다(현금 먼저, 종목은 EQUITIES 순서).
    def flatten_holdings(holdings)
      holdings.flat_map do |account_code, h|
        [[account_code, Asset::CASH_CODE, h[:cash]]] + h[:stocks].map { |code, qty| [account_code, code, qty] }
      end
    end

    def positions(holdings)
      flatten_holdings(holdings).map { |acc, asset, qty| { account_code: acc, asset_code: asset, qty: qty } }
    end

    def ledger_entries(holdings)
      flatten_holdings(holdings).map do |acc, asset, qty|
        { idem_key: "seed:open:#{acc}:#{asset}", from_account_code: DEPOSITORY_CODE, to_account_code: acc,
          asset_code: asset, qty: qty }
      end
    end

    def market_days
      (0...MARKET_DAYS).map do |n|
        day = FIRST_MARKET_DAY + n
        { trade_date: day, business_day: !(day.saturday? || day.sunday?) }
      end
    end
  end
end
