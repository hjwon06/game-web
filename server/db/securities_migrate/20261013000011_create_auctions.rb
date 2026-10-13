# 단일가 매매 실행 기록. 종목 · 거래일 · 세션(open 시가 · close 종가)마다 최대 1행이라 "그날 시가를 이미 돌렸다"의 근거다.
# price 는 체결이 없으면 NULL 이고 qty 는 그때 0 이다. mode 가 sequential(끄기 스위치) 이면 가격이 하나가 아니므로 price 는 항상 NULL 이다.
class CreateAuctions < ActiveRecord::Migration[8.1]
  def change
    create_table :auctions do |t|
      t.references :asset, null: false, foreign_key: true, index: false
      t.date :trade_date, null: false
      t.string :session, null: false
      t.string :mode, null: false
      t.bigint :price
      t.bigint :qty, null: false, default: 0
      t.timestamptz :ran_at, null: false

      t.index [:asset_id, :trade_date, :session], unique: true, name: "auctions_asset_date_session_uidx"
      t.check_constraint "session IN ('open','close')", name: "auctions_session_check"
      t.check_constraint "mode IN ('single','sequential')", name: "auctions_mode_check"
      t.check_constraint "qty >= 0", name: "auctions_qty_check"
      t.check_constraint "price IS NULL OR price > 0", name: "auctions_price_check"
      # single 은 가격과 수량이 함께 있거나 함께 없다. sequential 은 가격이 없다. NULL 은 CHECK 를 통과하므로 mode 별로 풀어 쓴다.
      t.check_constraint "(mode = 'single' AND ((price IS NULL) = (qty = 0))) OR (mode = 'sequential' AND price IS NULL)",
                         name: "auctions_price_qty_check"
    end
  end
end
