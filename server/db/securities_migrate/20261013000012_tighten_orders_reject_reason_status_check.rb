# 거절 사유 제약을 양방향으로 조인다(시뮬레이터 규칙): rejected 이면 사유가 반드시 있고, 사유가 있으면 rejected 다.
# 기존 제약(reject_reason IS NULL OR status = 'rejected')은 "사유 없는 rejected"를 통과시켰다.
# 이름은 그대로 두어 모델 주석 · 위반 테스트가 같은 이름을 가리킨다. 기존 행에 사유 없는 rejected 가 있으면
# 제약 추가가 실패하므로 먼저 세어 보고 멈춘다(PlaceOrder 는 거절마다 사유를 넣어 왔다).
class TightenOrdersRejectReasonStatusCheck < ActiveRecord::Migration[8.1]
  NAME = "orders_reject_reason_status_check".freeze

  def up
    bad = select_value("SELECT count(*) FROM orders WHERE status = 'rejected' AND reject_reason IS NULL").to_i
    raise "사유 없는 rejected 주문이 #{bad}건 있다. 제약을 걸기 전에 먼저 정리해야 한다" if bad.positive?

    remove_check_constraint :orders, name: NAME
    add_check_constraint :orders, "(status = 'rejected') = (reject_reason IS NOT NULL)", name: NAME
  end

  def down
    remove_check_constraint :orders, name: NAME
    add_check_constraint :orders, "reject_reason IS NULL OR status = 'rejected'", name: NAME
  end
end
