require "test_helper"

# 표의 CHECK · UNIQUE · FK · NOT NULL 이 DB 에서 거부되는지 본다. 모델 검증을 거치지 않도록 raw SQL 로 넣는다.
# 위반마다 savepoint 를 따로 열어 한 건이 바깥 트랜잭션(테스트)을 중단시키지 않게 한다.
# 위반 1건 = 정상 행에서 값 하나만 바꾼 것이다. 정상 행 자체가 들어가는지는 "정상 행" 테스트가 먼저 보인다.
Securities::Record.name # securities 풀이 트랜잭션 픽스처 설정보다 먼저 만들어지게 상수를 미리 로드한다

class Securities::ConstraintsTest < ActiveSupport::TestCase
  CHECK = ActiveRecord::CheckViolation
  UNIQUE = ActiveRecord::RecordNotUnique
  NOT_NULL = ActiveRecord::NotNullViolation
  FK = ActiveRecord::InvalidForeignKey

  setup do
    @seq = 0
    @asset_id = insert(:assets, asset)
    @buyer_id = insert(:accounts, account)
    @seller_id = insert(:accounts, account)
    @order_id = insert(:orders, order)
    @sell_order_id = insert(:orders, order(side: "sell"))
    @settlement_id = insert(:settlements, settlement)
    insert(:executions, execution)
    insert(:holds, hold)
    insert(:positions, position)
    insert(:ledger_entries, entry)
    insert(:market_days, { trade_date: Date.new(2026, 11, 2), business_day: true }, returning: "trade_date")
  end

  # [이름, 예외 클래스, 메시지에 있어야 할 것(제약 이름·컬럼), 위반 입력을 만드는 블록]
  VIOLATIONS = [
    ["assets.code 중복", UNIQUE, "assets_code_uidx", -> { insert(:assets, asset(code: row(:assets)["code"])) }],
    ["assets.kind 범위 밖", CHECK, "assets_kind_check", -> { insert(:assets, asset(kind: "bond")) }],
    ["assets 종목인데 base_price 0", CHECK, "assets_base_price_check", -> { insert(:assets, asset(base_price: 0)) }],
    ["assets 종목인데 base_price NULL", CHECK, "assets_base_price_check", -> { insert(:assets, asset(base_price: nil)) }],
    ["assets 현금인데 base_price 있음", CHECK, "assets_base_price_check",
     -> { insert(:assets, asset(kind: "cash", base_price: 1)) }],
    ["assets.name NULL", NOT_NULL, 'column "name"', -> { insert(:assets, asset(name: nil)) }],

    ["accounts.code 중복", UNIQUE, "accounts_code_uidx", -> { insert(:accounts, account(code: row(:accounts)["code"])) }],
    ["accounts.kind 범위 밖", CHECK, "accounts_kind_check", -> { insert(:accounts, account(kind: "bank")) }],

    ["positions (account, asset) 중복", UNIQUE, "positions_account_asset_uidx", -> { insert(:positions, position) }],
    ["positions.qty 음수", CHECK, "positions_qty_check",
     -> { insert(:positions, position(account_id: @seller_id, qty: -1)) }],
    ["positions.asset_id 가 없는 자산", FK, "Key (asset_id)=", -> { insert(:positions, position(account_id: @seller_id, asset_id: 0)) }],

    ["holds.order_id 중복", UNIQUE, "holds_order_uidx", -> { insert(:holds, hold) }],
    ["holds.qty 음수", CHECK, "holds_qty_check", -> { insert(:holds, hold(order_id: @sell_order_id, qty: -1)) }],
    ["holds.order_id 가 없는 주문", FK, "Key (order_id)=", -> { insert(:holds, hold(order_id: 0)) }],
    ["holds.account_id 가 없는 계좌", FK, "Key (account_id)=",
     -> { insert(:holds, hold(order_id: @sell_order_id, account_id: 0)) }],
    ["holds.asset_id 가 없는 자산", FK, "Key (asset_id)=",
     -> { insert(:holds, hold(order_id: @sell_order_id, asset_id: 0)) }],

    ["orders.client_key 중복", UNIQUE, "orders_client_key_uidx", -> { insert(:orders, order(client_key: row(:orders)["client_key"])) }],
    ["orders.seq 중복", UNIQUE, "orders_seq_uidx", -> { insert(:orders, order(seq: row(:orders)["seq"])) }],
    ["orders.side 범위 밖", CHECK, "orders_side_check", -> { insert(:orders, order(side: "hold")) }],
    ["orders.order_type 범위 밖", CHECK, "orders_order_type_check", -> { insert(:orders, order(order_type: "stop")) }],
    ["orders 지정가인데 price NULL", CHECK, "orders_price_check", -> { insert(:orders, order(price: nil)) }],
    ["orders 지정가인데 price 0", CHECK, "orders_price_check", -> { insert(:orders, order(price: 0)) }],
    ["orders 시장가인데 price 있음", CHECK, "orders_price_check",
     -> { insert(:orders, order(order_type: "market", price: 100)) }],
    ["orders.qty 0", CHECK, "orders_qty_check", -> { insert(:orders, order(qty: 0)) }],
    ["orders.filled_qty 가 qty 초과", CHECK, "orders_filled_qty_check", -> { insert(:orders, order(qty: 10, filled_qty: 11)) }],
    ["orders.filled_qty 음수", CHECK, "orders_filled_qty_check", -> { insert(:orders, order(filled_qty: -1)) }],
    ["orders.status 범위 밖", CHECK, "orders_status_check", -> { insert(:orders, order(status: "open")) }],
    ["orders.account_id 가 없는 계좌", FK, "Key (account_id)=", -> { insert(:orders, order(account_id: 0)) }],
    # 양방향: rejected 면 사유가 반드시 있고, 사유가 있으면 rejected 다(orders_reject_reason_status_check).
    ["orders rejected 인데 reject_reason NULL", CHECK, "orders_reject_reason_status_check",
     -> { insert(:orders, order(status: "rejected")) }],
    ["orders 접수인데 reject_reason 있음", CHECK, "orders_reject_reason_status_check",
     -> { insert(:orders, order(reject_reason: "tick")) }],
    ["orders.reject_reason 범위 밖", CHECK, "orders_reject_reason_check",
     -> { insert(:orders, order(status: "rejected", reject_reason: "other")) }],

    ["executions.price 0", CHECK, "executions_price_check", -> { insert(:executions, execution(price: 0)) }],
    ["executions.qty 0", CHECK, "executions_qty_check", -> { insert(:executions, execution(qty: 0)) }],
    ["executions.trade_date NULL", NOT_NULL, 'column "trade_date"', -> { insert(:executions, execution(trade_date: nil)) }],
    ["executions.settlement_id 가 없는 결제", FK, "Key (settlement_id)=",
     -> { insert(:executions, execution(settlement_id: 0)) }],

    ["settlements.settle_date 중복", UNIQUE, "settlements_settle_date_uidx",
     -> { insert(:settlements, settlement(settle_date: row(:settlements)["settle_date"])) }],
    ["settlements.status 범위 밖", CHECK, "settlements_status_check",
     -> { insert(:settlements, settlement(settle_date: Date.new(2026, 11, 5), status: "done")) }],

    ["ledger_entries 보내는 쪽 = 받는 쪽", CHECK, "ledger_entries_accounts_differ_check",
     -> { insert(:ledger_entries, entry(idem_key: "v-same", to_account_id: @seller_id)) }],
    ["ledger_entries.qty 0", CHECK, "ledger_entries_qty_check", -> { insert(:ledger_entries, entry(idem_key: "v-qty", qty: 0)) }],
    ["ledger_entries.idem_key 중복", UNIQUE, "ledger_entries_idem_key_uidx", -> { insert(:ledger_entries, entry) }],
    ["ledger_entries.settlement_id NULL", NOT_NULL, 'column "settlement_id"',
     -> { insert(:ledger_entries, entry(idem_key: "v-null", settlement_id: nil)) }],
    ["ledger_entries.asset_id 가 없는 자산", FK, "Key (asset_id)=",
     -> { insert(:ledger_entries, entry(idem_key: "v-fk", asset_id: 0)) }],

    ["market_days.business_day NULL", NOT_NULL, 'column "business_day"',
     -> { insert(:market_days, { trade_date: Date.new(2026, 11, 3), business_day: nil }, returning: "trade_date") }],
    ["market_days.trade_date 중복", UNIQUE, "market_days_pkey",
     -> { insert(:market_days, { trade_date: Date.new(2026, 11, 2), business_day: true }, returning: "trade_date") }]
  ].freeze

  test "정상 행은 9개 테이블 모두 들어간다(위반 테스트의 기준선)" do
    %w[assets accounts positions holds orders executions settlements ledger_entries market_days].each do |table|
      assert_operator count(table), :>=, 1, "#{table} 에 정상 행이 들어가지 않았다"
    end
  end

  test "거절 주문은 사유와 함께라면 들어간다(위 양방향 위반 테스트의 기준선)" do
    id = insert(:orders, order(status: "rejected", reject_reason: "insufficient"))

    row = conn.uncached { conn.select_one("SELECT status, reject_reason FROM orders WHERE id = #{id.to_i}") }
    assert_equal %w[rejected insufficient], [row["status"], row["reject_reason"]]
  end

  test "도우미 자체 검사: 쿼리 캐시를 켜도 같은 INSERT 두 번째는 DB 가 거부한다" do
    cols = asset(code: "VX-DUP")
    Securities::Record.cache do
      assert_kind_of Integer, insert(:assets, cols)

      error = assert_raises(UNIQUE) do
        Securities::Record.transaction(requires_new: true) { insert(:assets, cols) }
      end
      assert_includes error.message, "assets_code_uidx"
      assert_equal 1, conn.uncached { conn.select_value("SELECT count(*) FROM assets WHERE code = 'VX-DUP'") }.to_i
    end
  end

  VIOLATIONS.each do |label, error_class, needle, body|
    test "DB 가 거부한다: #{label}" do
      error = assert_raises(error_class) do
        Securities::Record.transaction(requires_new: true) { instance_exec(&body) }
      end
      assert_includes error.message, needle
    end
  end

  private

  def conn
    Securities::Record.lease_connection
  end

  # 도우미는 전부 쿼리 캐시를 건너뛴다. 캐시를 타면 글자까지 같은 INSERT 가 DB 에 가지 않고
  # 이전 결과(같은 id)가 돌아와 UNIQUE 위반이 일어나지 않은 것처럼 보인다.
  def count(table)
    conn.uncached { conn.select_value("SELECT count(*) FROM #{conn.quote_table_name(table)}") }.to_i
  end

  # 이 테스트가 넣은 첫 행(위반이 겹쳐야 할 대상)을 읽는다.
  def row(table)
    conn.uncached { conn.select_one("SELECT * FROM #{conn.quote_table_name(table)} ORDER BY 1 LIMIT 1") }
  end

  def insert(table, cols, returning: "id")
    names = cols.keys.map { |k| conn.quote_column_name(k) }.join(", ")
    values = cols.values.map { |v| conn.quote(v) }.join(", ")
    conn.uncached do
      conn.select_value("INSERT INTO #{conn.quote_table_name(table)} (#{names}) VALUES (#{values}) RETURNING #{returning}")
    end
  end

  def token(prefix)
    "#{prefix}-#{@seq += 1}"
  end

  def asset(**o)
    { code: token("VA"), name: "가상종목", kind: "equity", base_price: 1000 }.merge(o)
  end

  def account(**o)
    { code: token("VC"), name: "가상계좌", kind: "investor" }.merge(o)
  end

  def order(**o)
    { client_key: token("ck"), account_id: @buyer_id, asset_id: @asset_id, side: "buy", order_type: "limit",
      price: 1000, qty: 10, filled_qty: 0, status: "accepted" }.merge(o)
  end

  def settlement(**o)
    { settle_date: Date.new(2026, 11, 4), status: "pending" }.merge(o)
  end

  def execution(**o)
    { asset_id: @asset_id, buy_order_id: @order_id, sell_order_id: @sell_order_id, price: 1000, qty: 5,
      trade_date: Date.new(2026, 11, 2), settle_date: Date.new(2026, 11, 4), settlement_id: nil }.merge(o)
  end

  def hold(**o)
    { order_id: @order_id, account_id: @buyer_id, asset_id: @asset_id, qty: 10 }.merge(o)
  end

  def position(**o)
    { account_id: @buyer_id, asset_id: @asset_id, qty: 10 }.merge(o)
  end

  def entry(**o)
    { settlement_id: @settlement_id, from_account_id: @seller_id, to_account_id: @buyer_id, asset_id: @asset_id,
      qty: 10, idem_key: "base-entry" }.merge(o)
  end
end
