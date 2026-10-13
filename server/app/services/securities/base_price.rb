# 기준가 갱신. 시뮬레이터 규칙이다(거래소 원문은 확인하지 않았다).
#   - 기준가 = 그날 그 종목의 마지막 체결(executed_at 최대, 같으면 id 최대)의 가격이다.
#     종가 세션이 체결되면 그 체결이 그날 마지막이라 종가 단일가 가격이고(단일가를 켜면 그 가격 하나, 끄면 마지막 체결),
#     종가 세션이 비면 장중 마지막 체결가가 기준가가 된다.
#   - 그날 체결이 하나도 없으면 기준가는 그대로이고 nil 을 돌려준다.
#   - close 행이 없으면 종가가 아직 안 돈 것이라 예외를 낸다(어제 값으로 조용히 넘어가지 않는다).
#   - 절대값 대입이라 두 번 불러도 같다. 호출자(Schedule.run!)가 종가 일정 안에서 close! 다음에 부른다.
#   - Sim::Book.as_of 의 base 가 같은 규칙(체결일 < date 의 마지막 체결)으로 아침 기준가를 다시 만든다.
module Securities
  module BasePrice
    class NoClose < StandardError; end

    module_function

    # 갱신했으면 새 기준가, 그날 체결이 없어 그대로 뒀으면 nil.
    def roll!(asset:, trade_date:)
      closed = Auction.exists?(asset_id: asset.id, trade_date: trade_date, session: "close")
      raise NoClose, "#{asset.code} #{trade_date} 종가 행이 없다" unless closed

      price = Execution.where(asset_id: asset.id, trade_date: trade_date)
                       .order(executed_at: :desc, id: :desc).limit(1).pick(:price)
      return nil unless price

      asset.update!(base_price: price)
      price
    end
  end
end
