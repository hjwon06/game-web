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

ActiveRecord::Schema[8.1].define(version: 2026_10_07_000004) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

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

  create_table "sessions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
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
    t.index ["code"], name: "index_work_orders_on_code", unique: true
    t.index ["id", "machine_id"], name: "index_work_orders_on_id_and_machine_id", unique: true
    t.index ["machine_id"], name: "index_work_orders_one_active_per_machine", unique: true, where: "((status)::text = 'active'::text)"
    t.check_constraint "produced_qty >= 0", name: "work_orders_produced_qty_check"
    t.check_constraint "status::text = ANY (ARRAY['queued'::character varying, 'active'::character varying, 'done'::character varying]::text[])", name: "work_orders_status_check"
    t.check_constraint "target_qty > 0", name: "work_orders_target_qty_check"
  end

  add_foreign_key "commands", "machines"
  add_foreign_key "machine_state_events", "commands"
  add_foreign_key "machine_state_events", "machines"
  add_foreign_key "production_events", "machines"
  add_foreign_key "production_events", "work_orders"
  add_foreign_key "production_events", "work_orders", column: ["work_order_id", "machine_id"], primary_key: ["id", "machine_id"], name: "fk_production_events_work_order_machine"
  add_foreign_key "sessions", "users"
  add_foreign_key "work_orders", "machines"
end
