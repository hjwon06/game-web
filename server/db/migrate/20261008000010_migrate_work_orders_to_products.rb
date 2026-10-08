# work_orders.product(문자열) -> products 시드 + product_id 백필.
# product 문자열 컬럼은 bin/sim 이 아직 쓰므로 지우지 않는다.
# 정규화: 앞뒤/연속 공백 접기 + 소문자 비교. 표기 변형은 하나의 product 가 된다.
class MigrateWorkOrdersToProducts < ActiveRecord::Migration[8.1]
  def up
    add_reference :work_orders, :product, null: true, foreign_key: true, index: true
    add_reference :work_orders, :sales_order_line, null: true, foreign_key: true, index: true

    execute <<~SQL
      INSERT INTO products (sku, name, uom, kind, created_at, updated_at)
      SELECT 'WO-P' || lpad(row_number() OVER (ORDER BY n)::text, 4, '0'), name, 'ea', 'fg', now(), now()
      FROM (
        SELECT lower(regexp_replace(btrim(product), '\\s+', ' ', 'g')) AS n,
               min(regexp_replace(btrim(product), '\\s+', ' ', 'g')) AS name
        FROM work_orders GROUP BY 1
      ) d
    SQL

    execute <<~SQL
      UPDATE work_orders w SET product_id = p.id
      FROM products p
      WHERE lower(regexp_replace(btrim(p.name), '\\s+', ' ', 'g')) =
            lower(regexp_replace(btrim(w.product), '\\s+', ' ', 'g'))
    SQL

    unmatched = select_value("SELECT count(*) FROM work_orders WHERE product_id IS NULL").to_i
    raise "work_orders 백필 매칭 실패 #{unmatched}건" if unmatched.positive?

    change_column_null :work_orders, :product_id, false
  end

  def down
    remove_reference :work_orders, :sales_order_line, foreign_key: true, index: true
    remove_reference :work_orders, :product, foreign_key: true, index: true
  end
end
