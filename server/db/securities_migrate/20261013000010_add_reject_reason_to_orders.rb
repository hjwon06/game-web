# 거절 사유. rejected 주문에만 값이 있고 값은 네 가지뿐이다(시뮬레이터 규칙).
# 기존 행은 전부 NULL 이라 CHECK 를 바로 걸어도 통과한다.
class AddRejectReasonToOrders < ActiveRecord::Migration[8.1]
  def change
    add_column :orders, :reject_reason, :string

    add_check_constraint :orders, "reject_reason IN ('closed','tick','price_limit','insufficient')",
                         name: "orders_reject_reason_check"
    # NULL 이면 위 CHECK 는 통과한다. 이 제약이 "값이 있으면 rejected" 를 따로 보장한다.
    add_check_constraint :orders, "reject_reason IS NULL OR status = 'rejected'",
                         name: "orders_reject_reason_status_check"
  end
end
