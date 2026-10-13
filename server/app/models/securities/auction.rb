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

    # 종가 단일가를 돌린다. 시가와 같은 가격 결정 · 체결 · 끄기를 쓰고, 단일가 뒤 남은 주문은 전부 cancelled(장 마감 일괄 취소)다.
    # 그날 close 행이 있으면 그 행을 그대로 돌려준다.
    # 시뮬레이터 단순화: 15:30 뒤 랜덤엔드 시각 사이에 접수되는 주문은 Phase 대로 closed 로 거절한다.
    def self.close!(asset:, trade_date:, at:, single_price: nil)
      AuctionRun.call(asset: asset, trade_date: trade_date, at: at, single_price: single_price, session: "close")
    end

    # 랜덤엔드 시각. open 은 09:00, close 는 15:30 에 0..random_end_seconds 초(양끝 포함)를 더한다(Asia/Seoul).
    # Object#hash 는 프로세스마다 달라 쓰지 않고 SHA-256 으로 정한다 — 같은 인자면 어느 프로세스에서도 같은 값이다.
    def self.random_end_at(trade_date:, asset_id:, session:, seed:)
      raise ArgumentError, "session 은 #{SESSIONS.join('/')}" unless SESSIONS.include?(session)
      raise ArgumentError, "trade_date 는 Date" unless trade_date.is_a?(Date)

      # 시가 기준은 pre_open 이 끝나는 분(first[2], 09:00)이다. first[1] 은 pre_open 시작(08:30)이다.
      base_minute = session == "open" ? Phase::SCHEDULE.first[2] : Phase::SCHEDULE.last[2]
      digest = Digest::SHA256.hexdigest([trade_date.iso8601, asset_id, session, seed].join("|"))
      Clock.at_minute(trade_date, base_minute) + digest.to_i(16) % (Clock.random_end_seconds + 1)
    end

    # PlaceOrder 의 시작 문. 그 종목 그날 시가 행이 있으면 접속매매가 시작된 것이다.
    def self.opened?(asset_id:, trade_date:)
      exists?(asset_id: asset_id, trade_date: trade_date, session: "open")
    end
  end
end
