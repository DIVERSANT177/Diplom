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

ActiveRecord::Schema[8.0].define(version: 2026_03_29_064427) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "analyses", force: :cascade do |t|
    t.bigint "dashboard_id", null: false
    t.string "algorithm", null: false
    t.string "status", default: "pending"
    t.jsonb "params", default: {}
    t.jsonb "result", default: {}
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["dashboard_id"], name: "index_analyses_on_dashboard_id"
    t.index ["status"], name: "index_analyses_on_status"
  end

  create_table "cases", force: :cascade do |t|
    t.bigint "dashboard_id", null: false
    t.string "case_id", null: false
    t.string "project_id", null: false
    t.string "gender"
    t.integer "age_at_index"
    t.string "tumor_stage"
    t.string "vital_status"
    t.float "days_to_death"
    t.float "days_to_last_follow_up"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["case_id"], name: "index_cases_on_case_id"
    t.index ["dashboard_id"], name: "index_cases_on_dashboard_id"
    t.index ["project_id"], name: "index_cases_on_project_id"
  end

  create_table "dashboards", force: :cascade do |t|
    t.string "title"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "status", default: "draft"
    t.jsonb "projects", default: []
    t.jsonb "case_filters", default: {}
    t.jsonb "visualizations", default: []
    t.string "survival_endpoint", default: "OS"
    t.string "stratify_by"
    t.integer "top_genes_count", default: 50
    t.integer "total_cases"
    t.datetime "data_fetched_at"
    t.text "error_message"
    t.bigint "user_id", null: false
    t.string "expression_status", default: "pending"
    t.string "expression_error"
    t.index ["user_id"], name: "index_dashboards_on_user_id"
  end

  create_table "gene_expressions", force: :cascade do |t|
    t.bigint "dashboard_id", null: false
    t.string "case_id", null: false
    t.string "gene_id", null: false
    t.string "gene_name", null: false
    t.float "tpm", null: false
    t.string "project_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["dashboard_id", "case_id", "gene_id"], name: "idx_expression_unique", unique: true
    t.index ["dashboard_id", "case_id"], name: "index_gene_expressions_on_dashboard_id_and_case_id"
    t.index ["dashboard_id", "gene_id"], name: "index_gene_expressions_on_dashboard_id_and_gene_id"
    t.index ["dashboard_id"], name: "index_gene_expressions_on_dashboard_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  add_foreign_key "analyses", "dashboards"
  add_foreign_key "cases", "dashboards"
  add_foreign_key "dashboards", "users"
  add_foreign_key "gene_expressions", "dashboards"
end
