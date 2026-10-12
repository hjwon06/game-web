# 가능 수량 = 결제분 잔고(positions) + 미결제 체결로 들어올 것 − 나갈 것 − 열린 홀드(released_at NULL).
# 현금(asset.kind cash)은 체결가 × 수량으로 센다: 미결제 매도 체결은 들어올 현금, 미결제 매수 체결은 나갈 현금이다.
# 종목은 그 종목의 미결제 매수 체결 수량이 들어올 것, 매도 체결 수량이 나갈 것이다.
# 홀드 qty 는 체결마다 줄어든다(스키마 규칙). 체결된 만큼은 홀드가 아니라 체결이 이미 반영하므로 이중 차감이 없다.
# "미결제" = settlement 에 안 묶였거나(settlement_id NULL) 묶인 settlement 가 아직 settled 가 아닌 체결이다.
# 읽기 전용이다. 정합이 필요한 호출(PlaceOrder)은 계좌 행 FOR UPDATE 를 잡은 뒤에 부른다.
module Securities
  module Available
    module_function

    def for(account, asset)
      settled = Position.where(account_id: account.id, asset_id: asset.id).sum(:qty)
      held = Hold.where(account_id: account.id, asset_id: asset.id, released_at: nil).sum(:qty)
      incoming, outgoing = asset.kind == "cash" ? cash_flows(account) : equity_flows(account, asset)

      settled + incoming - outgoing - held
    end

    def unsettled
      Execution.left_joins(:settlement).where("executions.settlement_id IS NULL OR settlements.status <> 'settled'")
    end

    def cash_flows(account)
      amount = Arel.sql("executions.price * executions.qty")
      incoming = unsettled.joins(:sell_order).where(orders: { account_id: account.id }).sum(amount)
      outgoing = unsettled.joins(:buy_order).where(orders: { account_id: account.id }).sum(amount)
      [incoming, outgoing]
    end

    def equity_flows(account, asset)
      scope = unsettled.where(asset_id: asset.id)
      incoming = scope.joins(:buy_order).where(orders: { account_id: account.id }).sum("executions.qty")
      outgoing = scope.joins(:sell_order).where(orders: { account_id: account.id }).sum("executions.qty")
      [incoming, outgoing]
    end
  end
end
