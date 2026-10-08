# 작업 자원: 지게차·도크·작업자. tasks.resource_id 가 가리킨다. 시드 12개는 Resource.ensure_defaults! (재실행 안전).
class CreateResources < ActiveRecord::Migration[8.1]
  def up
    create_table :resources do |t|
      t.string :kind, null: false
      t.string :code, null: false
      t.references :home_location, null: true, foreign_key: { to_table: :locations }
      t.timestamps

      t.index :code, unique: true
      t.check_constraint "kind IN ('forklift','dock_in','dock_out','worker')", name: "resources_kind_check"
    end

    Resource.reset_column_information
    Resource.ensure_defaults!
  end

  def down
    drop_table :resources
  end
end
