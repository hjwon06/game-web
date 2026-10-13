# 단일가 매매 실행 기록. 종목 · 거래일 · 세션마다 1행이라 같은 날 시가를 두 번 돌려도 한 번만 일어난다.
# 이 행이 "그날 접속매매가 시작됐다"는 표시이기도 하다(PlaceOrder 의 시작 문). 실행은 Securities::AuctionRun.
module Securities
  class Auction < Record
    self.table_name = "auctions"

    SESSIONS = %w[open close].freeze
    MODES = %w[single sequential].freeze

    belongs_to :asset, class_name: "Securities::Asset"

    # 시가 단일가를 돌린다. 이미 돌았으면 그 행을 그대로 돌려준다(체결은 다시 일어나지 않는다).
    # single_price: nil 이면 config/securities_clock.yml 의 끄기 스위치를 읽는다.
    def self.open!(asset:, trade_date:, at:, single_price: nil)
      AuctionRun.call(asset: asset, trade_date: trade_date, at: at, single_price: single_price)
    end

    # PlaceOrder 의 시작 문. 그 종목 그날 시가 행이 있으면 접속매매가 시작된 것이다.
    def self.opened?(asset_id:, trade_date:)
      exists?(asset_id: asset_id, trade_date: trade_date, session: "open")
    end
  end
end
