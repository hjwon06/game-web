# 물리 위치 마이너스 금지를 행 안의 플래그(negative_allowed)가 아니라 locations.kind 로 강제한다.
# 플래그는 raw SQL 로 true 로 바꾸면 CHECK 를 우회했다. 트리거는 INSERT/UPDATE 마다 위치의 kind 를 직접 본다.
# 한계: locations.kind 를 나중에 바꾸는 경우는 보지 않는다(위치 9개는 고정 데이터이고 kind 변경 경로가 없다).
class ReplaceQuantsNegativeAllowedWithTrigger < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :quants, name: "quants_physical_non_negative_check"
    remove_column :quants, :negative_allowed

    execute <<~SQL
      CREATE FUNCTION quants_physical_non_negative() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.qty < 0 AND EXISTS (SELECT 1 FROM locations WHERE id = NEW.location_id AND kind = 'physical') THEN
          RAISE EXCEPTION 'quants_physical_non_negative: physical location % cannot hold negative qty (%)', NEW.location_id, NEW.qty
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$
    SQL
    execute <<~SQL
      CREATE TRIGGER quants_physical_non_negative BEFORE INSERT OR UPDATE ON quants
      FOR EACH ROW EXECUTE FUNCTION quants_physical_non_negative()
    SQL
  end

  def down
    execute "DROP TRIGGER quants_physical_non_negative ON quants"
    execute "DROP FUNCTION quants_physical_non_negative()"
    add_column :quants, :negative_allowed, :boolean, null: false, default: false
    execute "UPDATE quants SET negative_allowed = true WHERE location_id IN (SELECT id FROM locations WHERE kind = 'virtual')"
    add_check_constraint :quants, "qty >= 0 OR negative_allowed", name: "quants_physical_non_negative_check"
  end
end
