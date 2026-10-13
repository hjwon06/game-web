# 기준가 갱신. 시뮬레이터 규칙이다(거래소 원문은 확인하지 않았다).
#   - 그날 그 종목 close 행(auctions)의 ran_at 에 난 체결 중 id 가 가장 큰 체결의 가격이 assets.base_price 가 된다.
#     종가 세션의 마지막 체결가다(단일가를 켜면 그 가격 하나, 끄면 마지막 체결).
#   - 장중 체결은 보지 않는다. 종가 세션에 체결이 없으면 기준가는 그대로다(장중에 체결이 있어도 유지).
#   - close 행이 없으면 종가가 아직 안 돈 것이라 예외를 낸다(어제 값으로 조용히 넘어가지 않는다).
#   - 절대값 대입이라 두 번 불러도 같다. 호출자(Schedule.run!)가 종가 일정 안에서 close! 다음에 부른다.
module Securities
  module BasePrice
    class NoClose < StandardError; end

    module_function

    # 갱신했으면 새 기준가, 종가 세션 체결이 없어 그대로 뒀으면 nil.
    def roll!(asset:, trade_date:)
      close = Auction.find_by(asset_id: asset.id, trade_date: trade_date, session: "close")
      raise NoClose, "#{asset.code} #{trade_date} 종가 행이 없다" unless close

      price = Execution.where(asset_id: asset.id, trade_date: trade_date, executed_at: close.ran_at)
                       .order(id: :desc).limit(1).pick(:price)
      return nil unless price

      asset.update!(base_price: price)
      price
    end
  end
end
