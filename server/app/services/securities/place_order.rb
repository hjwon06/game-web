# 주문 접수. 시뮬레이터 규칙이다(거래소 원문은 확인하지 않았다).
# 잠금 순서는 모든 경로에서 "client_key advisory lock → 계좌 행 FOR UPDATE" 하나뿐이다.
#   - 같은 키 요청은 advisory 에서 직렬화된다. 먼저 온 쪽이 커밋하면 뒤 요청의 조회가 그 주문을 본다.
#   - 서로 다른 키라도 같은 계좌면 계좌 행에서 직렬화된다. 가능 수량은 이 잠금을 쥔 채 읽는다.
#   - orders · holds INSERT 의 FK 검사는 계좌 행에 KEY SHARE 를 잡는다. FOR UPDATE 를 먼저 잡아 두면
#     뒤 요청이 INSERT 이전에 줄을 서서 교착이 나지 않는다.
#   - 접수 뒤 체결(Match)은 그 다음 잠금(책 잠금 → 주문 행)을 같은 트랜잭션에서 이어 잡는다. 순서 전체는 match.rb 머리말.
# 거절 순서: closed(장 단계) → tick(호가 단위) → price_limit(가격제한) → insufficient(가능 수량). 거절은 홀드가 없다.
# 홀드: 매수 지정가 = 가격 × 수량(현금) · 매수 시장가 = 상한가 × 수량(현금) · 매도 = 종목 수량.
module Securities
  class PlaceOrder
    class Conflict < StandardError; end

    def self.call(**args)
      new(**args).call
    end

    def initialize(account:, asset:, side:, order_type:, qty:, price:, client_key:, at:)
      @account = account
      @asset = asset
      @side = side.to_s
      @order_type = order_type.to_s
      @qty = qty
      @price = price
      @key = client_key
      @at = at
      validate!
    end

    def call
      Record.transaction do
        lock_key
        existing = Order.find_by(client_key: @key)
        next replay(existing) if existing

        Account.lock.find(@account.id) # FOR UPDATE. 이후 가능 수량 읽기와 INSERT 가 이 잠금 안에서 일어난다.
        place
      end
    end

    private

    def validate!
      raise ArgumentError, "투자자 계좌만 주문할 수 있다" unless @account.is_a?(Account) && @account.kind == "investor"
      raise ArgumentError, "종목만 주문할 수 있다" unless @asset.is_a?(Asset) && @asset.kind == "equity"
      raise ArgumentError, "side 는 #{Order::SIDES.join('/')}" unless Order::SIDES.include?(@side)
      raise ArgumentError, "order_type 은 #{Order::ORDER_TYPES.join('/')}" unless Order::ORDER_TYPES.include?(@order_type)
      raise ArgumentError, "qty 는 양의 정수" unless @qty.is_a?(Integer) && @qty.positive?
      raise ArgumentError, "client_key 가 비었다" unless @key.is_a?(String) && !@key.empty?

      limit = @order_type == "limit"
      raise ArgumentError, "지정가는 양의 정수 가격이 필요하다" if limit && !(@price.is_a?(Integer) && @price.positive?)
      raise ArgumentError, "시장가는 가격이 없어야 한다" if !limit && !@price.nil?
    end

    def lock_key
      sql = Record.sanitize_sql(["SELECT pg_advisory_xact_lock(hashtext(?))", "securities:order:#{@key}"])
      Record.lease_connection.execute(sql)
    end

    # 같은 키 · 같은 내용이면 처음 결과(거절 포함)를 그대로 돌려준다. 내용이 다르면 기존 행을 건드리지 않고 Conflict.
    def replay(order)
      same = order.account_id == @account.id && order.asset_id == @asset.id && order.side == @side &&
             order.order_type == @order_type && order.qty == @qty && order.price == @price
      raise Conflict, "client_key #{@key} 는 다른 내용의 주문에 이미 쓰였다" unless same

      order
    end

    def place
      reason = reject_reason
      return create_order("rejected", reason) if reason

      order = create_order("accepted")
      Hold.create!(order: order, account: @account, asset: hold_asset, qty: hold_qty)
      # 접속매매(continuous)만 접수 즉시 체결한다. pre_open · closing 접수분은 체결 없이 남긴다(단일가는 ④ 몫).
      phase == :continuous ? Match.call(order: order, at: @at) : order
    end

    def phase
      @phase ||= Phase.at(@at)
    end

    def reject_reason
      return "closed" if phase == :closed

      if @order_type == "limit"
        return "tick" unless Tick.valid?(@price)
        return "price_limit" unless @price.between?(*Tick.limits(@asset.base_price))
      end

      "insufficient" if Available.for(@account, hold_asset) < hold_qty
    end

    def create_order(status, reason = nil)
      Order.create!(client_key: @key, account: @account, asset: @asset, side: @side, order_type: @order_type,
                    price: @price, qty: @qty, status: status, reject_reason: reason, accepted_at: @at)
    end

    def hold_asset
      @hold_asset ||= @side == "buy" ? Asset.find_by!(code: Asset::CASH_CODE) : @asset
    end

    def hold_qty
      return @qty if @side == "sell"

      (@order_type == "limit" ? @price : Tick.limits(@asset.base_price).last) * @qty
    end
  end
end
