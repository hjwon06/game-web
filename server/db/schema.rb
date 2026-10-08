# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_08_000010) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "bom_lines", force: :cascade do |t|
    t.bigint "product_id", null: false
    t.bigint "component_id", null: false
    t.decimal "qty_per", precision: 14, scale: 3, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["component_id"], name: "index_bom_lines_on_component_id"
    t.index ["product_id", "component_id"], name: "index_bom_lines_on_product_id_and_component_id", unique: true
    t.check_constraint "product_id <> component_id", name: "bom_lines_not_self_check"
    t.check_constraint "qty_per > 0::numeric", name: "bom_lines_qty_per_check"
  end

  create_table "commands", force: :cascade do |t|
    t.uuid "idempotency_key", null: false
    t.bigint "machine_id", null: false
    t.string "kind", null: false
    t.integer "base_version", null: false
    t.integer "result_status"
    t.datetime "created_at", null: false
    t.index ["idempotency_key"], name: "index_commands_on_idempotency_key", unique: true
    t.index ["machine_id"], name: "index_commands_on_machine_id"
    t.check_constraint "base_version >= 0", name: "commands_base_version_check"
    t.check_constraint "kind::text = ANY (ARRAY['start'::character varying, 'stop'::character varying, 'break'::character varying, 'repair'::character varying]::text[])", name: "commands_kind_check"
  end

  create_table "inspections", force: :cascade do |t|
    t.bigint "lot_id", null: false
    t.bigint "work_order_id", null: false
    t.string "result", null: false
    t.decimal "defect_qty", precision: 14, scale: 3, default: "0.0", null: false
    t.timestamptz "inspected_at", default: -> { "now()" }, null: false
    t.bigint "stock_move_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["lot_id"], name: "index_inspections_on_lot_id"
    t.index ["stock_move_id"], name: "index_inspections_on_stock_move_id", unique: true
    t.index ["work_order_id"], name: "index_inspections_on_work_order_id"
    t.check_constraint "defect_qty >= 0::numeric", name: "inspections_defect_qty_check"
    t.check_constraint "result::text = ANY (ARRAY['pass'::character varying, 'fail'::character varying]::text[])", name: "inspections_result_check"
  end

  create_table "locations", force: :cascade do |t|
    t.string "code", null: false
    t.string "name", null: false
    t.string "kind", null: false
    t.string "role"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_locations_on_code", unique: true
    t.check_constraint "kind::text = ANY (ARRAY['physical'::character varying, 'virtual'::character varying]::text[])", name: "locations_kind_check"
  end

  create_table "lots", force: :cascade do |t|
    t.bigint "product_id", null: false
    t.string "lot_no", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["lot_no"], name: "index_lots_on_lot_no", unique: true
    t.index ["product_id"], name: "index_lots_on_product_id"
  end

  create_table "machine_state_events", force: :cascade do |t|
    t.bigint "machine_id", null: false
    t.bigint "command_id"
    t.string "from_state", null: false
    t.string "to_state", null: false
    t.integer "version", null: false
    t.timestamptz "at", null: false
    t.index ["machine_id", "version"], name: "index_machine_state_events_on_machine_id_and_version", unique: true
  end

  create_table "machines", force: :cascade do |t|
    t.string "code", null: false
    t.string "name", null: false
    t.string "state", default: "stopped", null: false
    t.integer "version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_machines_on_code", unique: true
    t.check_constraint "state::text = ANY (ARRAY['running'::character varying, 'stopped'::character varying, 'broken'::character varying]::text[])", name: "machines_state_check"
    t.check_constraint "version >= 0", name: "machines_version_check"
  end

  create_table "production_events", force: :cascade do |t|
    t.bigint "machine_id", null: false
    t.bigint "work_order_id", null: false
    t.timestamptz "bucket_start", null: false
    t.timestamptz "bucket_end", null: false
    t.integer "good_qty", null: false
    t.integer "defect_qty", null: false
    t.integer "machine_version", null: false
    t.index ["machine_id", "bucket_start"], name: "index_production_events_on_machine_id_and_bucket_start", unique: true
    t.check_constraint "good_qty >= 0 AND defect_qty >= 0", name: "production_events_qty_check"
    t.check_constraint "machine_version >= 0", name: "production_events_machine_version_check"
  end

  create_table "products", force: :cascade do |t|
    t.string "sku", null: false
    t.string "name", null: false
    t.string "uom", null: false
    t.string "kind", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["sku"], name: "index_products_on_sku", unique: true
    t.check_constraint "btrim(uom::text) <> ''::text", name: "products_uom_check"
    t.check_constraint "kind::text = ANY (ARRAY['raw'::character varying, 'wip'::character varying, 'fg'::character varying]::text[])", name: "products_kind_check"
  end

  create_table "quants", force: :cascade do |t|
    t.bigint "product_id", null: false
    t.bigint "lot_id"
    t.bigint "location_id", null: false
    t.decimal "qty", precision: 14, scale: 3, default: "0.0", null: false
    t.boolean "negative_allowed", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "product_id, COALESCE(lot_id, (0)::bigint), location_id", name: "index_quants_unique_slot", unique: true
    t.index ["location_id"], name: "index_quants_on_location_id"
    t.index ["lot_id"], name: "index_quants_on_lot_id"
    t.check_constraint "qty >= 0::numeric OR negative_allowed", name: "quants_physical_non_negative_check"
  end

  create_table "sales_order_lines", force: :cascade do |t|
    t.bigint "sales_order_id", null: false
    t.bigint "product_id", null: false
    t.decimal "ordered_qty", precision: 14, scale: 3, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["product_id"], name: "index_sales_order_lines_on_product_id"
    t.index ["sales_order_id"], name: "index_sales_order_lines_on_sales_order_id"
    t.check_constraint "ordered_qty > 0::numeric", name: "sales_order_lines_ordered_qty_check"
  end

  create_table "sales_orders", force: :cascade do |t|
    t.string "so_no", null: false
    t.string "customer", null: false
    t.date "due_date"
    t.string "status", default: "open", null: false
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.index ["so_no"], name: "index_sales_orders_on_so_no", unique: true
    t.check_constraint "status::text = ANY (ARRAY['open'::character varying, 'partial'::character varying, 'done'::character varying]::text[])", name: "sales_orders_status_check"
  end

  create_table "sessions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "stock_moves", force: :cascade do |t|
    t.bigint "product_id", null: false
    t.bigint "lot_id"
    t.bigint "from_location_id", null: false
    t.bigint "to_location_id", null: false
    t.decimal "qty", precision: 14, scale: 3, null: false
    t.string "move_type", null: false
    t.string "ref_type"
    t.bigint "ref_id"
    t.string "idempotency_key", null: false
    t.timestamptz "occurred_at", default: -> { "now()" }, null: false
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.index ["from_location_id"], name: "index_stock_moves_on_from_location_id"
    t.index ["idempotency_key"], name: "index_stock_moves_on_idempotency_key", unique: true
    t.index ["lot_id"], name: "index_stock_moves_on_lot_id"
    t.index ["product_id", "occurred_at"], name: "index_stock_moves_on_product_id_and_occurred_at"
    t.index ["ref_type", "ref_id"], name: "index_stock_moves_on_ref_type_and_ref_id"
    t.index ["to_location_id"], name: "index_stock_moves_on_to_location_id"
    t.check_constraint "from_location_id <> to_location_id", name: "stock_moves_locations_differ_check"
    t.check_constraint "move_type::text = ANY (ARRAY['receive'::character varying, 'putaway'::character varying, 'issue'::character varying, 'produce'::character varying, 'qc_pass'::character varying, 'qc_fail'::character varying, 'ship'::character varying]::text[])", name: "stock_moves_move_type_check"
    t.check_constraint "qty > 0::numeric", name: "stock_moves_qty_check"
  end

  create_table "users", force: :cascade do |t|
    t.string "name", null: false
    t.string "password_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_users_on_name", unique: true
  end

  create_table "work_orders", force: :cascade do |t|
    t.string "code", null: false
    t.bigint "machine_id", null: false
    t.string "product", null: false
    t.integer "target_qty", null: false
    t.integer "produced_qty", default: 0, null: false
    t.string "status", default: "queued", null: false
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "product_id", null: false
    t.bigint "sales_order_line_id"
    t.index ["code"], name: "index_work_orders_on_code", unique: true
    t.index ["id", "machine_id"], name: "index_work_orders_on_id_and_machine_id", unique: true
    t.index ["machine_id"], name: "index_work_orders_one_active_per_machine", unique: true, where: "((status)::text = 'active'::text)"
    t.index ["product_id"], name: "index_work_orders_on_product_id"
    t.index ["sales_order_line_id"], name: "index_work_orders_on_sales_order_line_id"
    t.check_constraint "produced_qty >= 0", name: "work_orders_produced_qty_check"
    t.check_constraint "status::text = ANY (ARRAY['queued'::character varying, 'active'::character varying, 'done'::character varying]::text[])", name: "work_orders_status_check"
    t.check_constraint "target_qty > 0", name: "work_orders_target_qty_check"
  end

  add_foreign_key "bom_lines", "products"
  add_foreign_key "bom_lines", "products", column: "component_id"
  add_foreign_key "commands", "machines"
  add_foreign_key "inspections", "lots"
  add_foreign_key "inspections", "stock_moves"
  add_foreign_key "inspections", "work_orders"
  add_foreign_key "lots", "products"
  add_foreign_key "machine_state_events", "commands"
  add_foreign_key "machine_state_events", "machines"
  add_foreign_key "production_events", "machines"
  add_foreign_key "production_events", "work_orders"
  add_foreign_key "production_events", "work_orders", column: ["work_order_id", "machine_id"], primary_key: ["id", "machine_id"], name: "fk_production_events_work_order_machine"
  add_foreign_key "quants", "locations"
  add_foreign_key "quants", "lots"
  add_foreign_key "quants", "products"
  add_foreign_key "sales_order_lines", "products"
  add_foreign_key "sales_order_lines", "sales_orders"
  add_foreign_key "sessions", "users"
  add_foreign_key "stock_moves", "locations", column: "from_location_id"
  add_foreign_key "stock_moves", "locations", column: "to_location_id"
  add_foreign_key "stock_moves", "lots"
  add_foreign_key "stock_moves", "products"
  add_foreign_key "work_orders", "machines"
  add_foreign_key "work_orders", "products"
  add_foreign_key "work_orders", "sales_order_lines"

  # --- 수동 보존 블록: schema.rb 덤퍼는 트리거/함수와 로케이션 시드를 출력하지 않는다. ---
  # db:migrate 가 이 파일을 재생성하면 이 블록이 사라지므로 diff 에서 확인하고 되살린다.
  # (근본 해결은 config.active_record.schema_format = :sql 전환 — 이번 담당 범위 밖)
  execute <<~SQL
    CREATE OR REPLACE FUNCTION stock_moves_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'stock_moves is append-only (% blocked)', TG_OP USING ERRCODE = 'restrict_violation';
    END;
    $$;
    DROP TRIGGER IF EXISTS stock_moves_no_update_delete ON stock_moves;
    CREATE TRIGGER stock_moves_no_update_delete BEFORE UPDATE OR DELETE ON stock_moves
      FOR EACH ROW EXECUTE FUNCTION stock_moves_append_only();
    DROP TRIGGER IF EXISTS stock_moves_no_truncate ON stock_moves;
    CREATE TRIGGER stock_moves_no_truncate BEFORE TRUNCATE ON stock_moves
      FOR EACH STATEMENT EXECUTE FUNCTION stock_moves_append_only();
    INSERT INTO locations (code, name, kind, role, created_at, updated_at) VALUES
      ('supplier',   '공급처',     'virtual',  'supplier',   now(), now()),
      ('customer',   '고객',       'virtual',  'customer',   now(), now()),
      ('production', '생산',       'virtual',  'production', now(), now()),
      ('scrap',      '폐기',       'virtual',  'scrap',      now(), now()),
      ('receiving',  '입고대',     'physical', 'receiving',  now(), now()),
      ('raw_store',  '자재창고',   'physical', 'storage',    now(), now()),
      ('qc',         '검사대',     'physical', 'qc',         now(), now()),
      ('fg_store',   '완제품창고', 'physical', 'storage',    now(), now()),
      ('shipping',   '출하대',     'physical', 'shipping',   now(), now())
    ON CONFLICT (code) DO NOTHING;
  SQL
end
