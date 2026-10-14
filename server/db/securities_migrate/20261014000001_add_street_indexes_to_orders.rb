# 거리 읽기 API(⑦a)가 쓰는 orders 인덱스 둘.
#   - orders_accepted_at_idx: "그날 접수된 주문" 집계와 "최근 120초" 창이 범위 스캔을 탄다.
#   - orders_open_asset_side_idx: 열린 주문(accepted · partially_filled)만 담는 부분 인덱스. 끝난 주문이 쌓여도 크기가 늘지 않는다.
#     WHERE 는 StreetRead::OPEN_SQL 과 같은 식이어야 플래너가 쓴다.
# 데몬이 쓰는 중에도 INSERT 를 막지 않게 CONCURRENTLY 로 만든다(그래서 DDL 트랜잭션을 끈다).
class AddStreetIndexesToOrders < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_index :orders, :accepted_at, name: "orders_accepted_at_idx", algorithm: :concurrently, if_not_exists: true
    add_index :orders, [:asset_id, :side], name: "orders_open_asset_side_idx", algorithm: :concurrently,
                                           where: "status IN ('accepted','partially_filled')", if_not_exists: true
  end

  def down
    remove_index :orders, name: "orders_open_asset_side_idx", algorithm: :concurrently, if_exists: true
    remove_index :orders, name: "orders_accepted_at_idx", algorithm: :concurrently, if_exists: true
  end
end
