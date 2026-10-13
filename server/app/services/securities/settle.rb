# D+2 결제(상계). 시뮬레이터 규칙이다(결제 시각 원문은 확인하지 않았다 — 영업일 D+2 시작 때 몰아서 처리).
# 그날(settle_date) 결제인데 아직 settlement 에 안 묶인 체결을 계좌 × 자산으로 상계해 청산 계좌(VCLR-001)와 맞바꾼다.
#   - 체결 1건: 매수자 +종목 −체결가×수량(현금), 매도자 반대. 계좌 × 자산으로 합한 순액 n 이
#     + 면 청산 → 계좌, − 면 계좌 → 청산 원장 행 1개, 0 이면 행이 없다. 청산 계좌의 자산별 합은 0 이 된다.
#   - 원장 · positions · 체결의 settlement_id · settlements 는 한 트랜잭션이다. 어느 하나라도 실패하면 전부 되돌아간다.
#   - 원장 idem_key 는 settle:날짜:계좌코드:자산코드.
#   - 멱등: 그날 settlements 행이 이미 settled 면 아무것도 쓰지 않고 그 행을 돌려준다.
#   - 체결이 없는 날도 settled 행 1개가 남는다(원장 · positions 변화 없음).
# 잠금 순서: 영향받는 계좌 행을 id 오름차순으로 FOR UPDATE → settlements 행. 접수(PlaceOrder)와 취소가 계좌 행을 먼저
# 잡는 것과 같은 방향이라 교착이 없다. 책 잠금은 잡지 않는다(결제는 호가를 건드리지 않는다).
#   - 같은 날 Settle 둘은 첫 계좌 행에서 직렬화된다. 늦은 쪽은 계좌 잠금을 얻은 뒤 체결을 다시 읽으므로 이미 묶인
#     체결이 없고, settlements 행이 settled 인 것을 보고 그대로 돌려준다.
#   - 청산 · 예탁 계좌는 잠그지 않는다. 원장 INSERT 의 FK 가 KEY SHARE 만 잡아 서로 막지 않는다.
# 미결제 몫(Available 이 세던 체결)이 positions 로 옮겨가는 것이라 결제 전후 가능 수량은 같다.
module Securities
  class Settle
    # 체결 1건에서 상계에 필요한 값만 뽑은 행(Securities::Fill 모듈과 이름이 겹치지 않게 Row 로 둔다).
    Row = Struct.new(:id, :asset_id, :price, :qty, :buyer_id, :seller_id)

    def self.call(settle_date:, at:)
      new(settle_date: settle_date, at: at).call
    end

    def initialize(settle_date:, at:)
      raise ArgumentError, "settle_date 는 Date" unless settle_date.is_a?(Date)

      today = at.in_time_zone(Phase::ZONE).to_date
      raise ArgumentError, "결제일(#{settle_date}) 전(#{today})에는 결제할 수 없다" if settle_date > today

      @date = settle_date
      @at = at
    end

    def call
      Record.transaction do
        fills = lock_accounts_and_read
        settlement = lock_settlement
        next settlement if settlement.status == "settled"

        apply(settlement, fills)
        settlement
      end
    end

    private

    # 영향받는 계좌를 id 순으로 잠그고, 잠근 뒤에 체결을 다시 읽는다. 읽은 뒤 계좌 집합이 달라졌으면 잠근 집합을
    # 넓혀 다시 읽는다(보통 한 바퀴에 끝난다). 이미 잡은 잠금은 다시 잡아도 그대로다.
    def lock_accounts_and_read
      locked = []
      loop do
        fills = pending_fills
        ids = fills.flat_map { |f| [f.buyer_id, f.seller_id] }.uniq.sort
        return fills if (ids - locked).empty?

        # 순액이 0 이라 원장 행이 안 생기는 계좌도 잠근다(ids 는 체결에서 뽑으므로 순액과 무관하다). 원장 행이 없으면
        # INSERT 의 FK 잠금(KEY SHARE)도 없고, Available.for 는 여러 문장이라 그 사이에 결제가 커밋되면 미결제 들어올
        # 것은 결제 전, 나갈 것은 결제 뒤로 읽혀 과다 판정 → 초과 매도가 된다. 이 명시 잠금만이 그 계좌를 막는다.
        Account.lock.where(id: ids).order(:id).pluck(:id) # FOR UPDATE ... ORDER BY id
        locked |= ids
      end
    end

    def pending_fills
      rows = Execution.where(settle_date: @date, settlement_id: nil)
                      .joins("JOIN orders b ON b.id = executions.buy_order_id JOIN orders s ON s.id = executions.sell_order_id")
                      .order(:id)
                      .pluck("executions.id", "executions.asset_id", "executions.price", "executions.qty",
                             "b.account_id", "s.account_id")
      rows.map { |row| Row.new(*row) }
    end

    # 그날 행이 없으면 pending 으로 만들고(동시 INSERT 는 UNIQUE 에서 대기 후 DO NOTHING) FOR UPDATE 로 읽는다.
    def lock_settlement
      Settlement.insert_all([{ settle_date: @date, status: "pending" }], unique_by: :settle_date)
      Settlement.lock.find_by!(settle_date: @date)
    end

    def apply(settlement, fills)
      nets = net(fills).reject { |_, n| n.zero? }
      write_ledger(settlement, nets)
      write_positions(nets)
      Execution.where(id: fills.map(&:id)).update_all(settlement_id: settlement.id) if fills.any?
      settlement.update!(status: "settled", settled_at: @at)
    end

    # { [계좌 id, 자산 id] => 순액 }. 종목은 수량, 현금은 체결가 × 수량이다.
    def net(fills)
      cash_id = Asset.find_by!(code: Asset::CASH_CODE).id
      fills.each_with_object(Hash.new(0)) do |f, sums|
        amount = f.price * f.qty
        sums[[f.buyer_id, f.asset_id]] += f.qty
        sums[[f.seller_id, f.asset_id]] -= f.qty
        sums[[f.buyer_id, cash_id]] -= amount
        sums[[f.seller_id, cash_id]] += amount
      end
    end

    def write_ledger(settlement, nets)
      return if nets.empty?

      clearing_id = Account.find_by!(code: Seed::CLEARING_CODE).id
      account_codes = Account.where(id: nets.keys.map(&:first).uniq).pluck(:id, :code).to_h
      asset_codes = Asset.where(id: nets.keys.map(&:last).uniq).pluck(:id, :code).to_h

      entries = nets.map do |(account_id, asset_id), n|
        from, to = n.positive? ? [clearing_id, account_id] : [account_id, clearing_id]
        { settlement_id: settlement.id, from_account_id: from, to_account_id: to, asset_id: asset_id, qty: n.abs,
          idem_key: "settle:#{@date}:#{account_codes.fetch(account_id)}:#{asset_codes.fetch(asset_id)}", created_at: @at }
      end
      LedgerEntry.insert_all!(entries) # 같은 idem_key 가 있으면 조용히 넘기지 않고 UNIQUE 위반으로 멈춘다
    end

    # 있는 행은 순액만큼 더하고 없는 행은 만든다. 음수가 되면 positions_qty_check 가 트랜잭션 전체를 되돌린다.
    def write_positions(nets)
      return if nets.empty?

      existing = Position.where(account_id: nets.keys.map(&:first)).pluck(:account_id, :asset_id, :id)
                         .to_h { |account_id, asset_id, id| [[account_id, asset_id], id] }
      fresh, known = nets.partition { |key, _| !existing.key?(key) }

      known.each { |key, n| Position.where(id: existing.fetch(key)).update_all(["qty = qty + ?", n]) }
      return if fresh.empty?

      Position.insert_all!(fresh.map { |(account_id, asset_id), n| { account_id: account_id, asset_id: asset_id, qty: n } })
    end
  end
end
