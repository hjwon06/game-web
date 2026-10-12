# 거래일 달력. 기본키가 날짜다.
class CreateMarketDays < ActiveRecord::Migration[8.1]
  def change
    create_table :market_days, id: :date, primary_key: :trade_date do |t|
      t.boolean :business_day, null: false
    end
  end
end
