# 거래일 달력. business_day 가 false 면 휴장(주말)이다.
module Securities
  class MarketDay < Record
    self.table_name = "market_days"
    self.primary_key = "trade_date"
  end
end
