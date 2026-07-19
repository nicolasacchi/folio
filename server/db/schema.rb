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

ActiveRecord::Schema[8.1].define(version: 2026_07_20_120000) do
  create_table "annotations", force: :cascade do |t|
    t.datetime "added_at"
    t.integer "book_id"
    t.text "cfi"
    t.string "color"
    t.text "content"
    t.datetime "created_at", null: false
    t.integer "device_id", null: false
    t.string "fingerprint", null: false
    t.string "kind", default: "highlight", null: false
    t.integer "location_end"
    t.integer "location_start"
    t.text "note"
    t.integer "page"
    t.string "raw_author"
    t.string "raw_title", null: false
    t.string "source", default: "clippings", null: false
    t.datetime "updated_at", null: false
    t.index ["book_id", "added_at"], name: "index_annotations_on_book_id_and_added_at"
    t.index ["book_id"], name: "index_annotations_on_book_id"
    t.index ["device_id", "fingerprint"], name: "index_annotations_on_device_id_and_fingerprint", unique: true
    t.index ["device_id"], name: "index_annotations_on_device_id"
    t.index ["kind"], name: "index_annotations_on_kind"
  end

  create_table "book_files", force: :cascade do |t|
    t.string "asin"
    t.boolean "available", default: true, null: false
    t.integer "book_id", null: false
    t.datetime "cde_parsed_at"
    t.string "cde_type"
    t.datetime "created_at", null: false
    t.string "format", null: false
    t.string "path", null: false
    t.datetime "prepared_at"
    t.string "prepared_path"
    t.string "prepared_sha256"
    t.integer "prepared_size"
    t.string "prepared_source_sha256"
    t.string "sha256", null: false
    t.integer "size", null: false
    t.string "source", default: "upload", null: false
    t.datetime "updated_at", null: false
    t.index ["book_id", "format"], name: "index_book_files_on_book_id_and_format", unique: true
    t.index ["book_id"], name: "index_book_files_on_book_id"
    t.index ["path"], name: "index_book_files_on_path", unique: true
    t.index ["sha256"], name: "index_book_files_on_sha256"
  end

  create_table "books", force: :cascade do |t|
    t.string "author"
    t.string "category"
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "enriched_at"
    t.string "enrichment_source"
    t.boolean "has_fulltext", default: false, null: false
    t.string "language"
    t.string "public_id", null: false
    t.integer "published_year"
    t.string "series"
    t.float "series_index"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index "lower(title)", name: "index_books_on_lower_title"
    t.index ["author"], name: "index_books_on_author"
    t.index ["category"], name: "index_books_on_category"
    t.index ["created_at"], name: "index_books_on_created_at"
    t.index ["has_fulltext"], name: "index_books_on_has_fulltext"
    t.index ["public_id"], name: "index_books_on_public_id", unique: true
    t.index ["series"], name: "index_books_on_series"
    t.index ["title"], name: "index_books_on_title"
  end

  create_table "conversions", force: :cascade do |t|
    t.integer "book_file_id", null: false
    t.integer "book_id", null: false
    t.datetime "created_at", null: false
    t.text "error"
    t.datetime "finished_at"
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.string "target_format", null: false
    t.datetime "updated_at", null: false
    t.index ["book_file_id"], name: "index_conversions_on_book_file_id"
    t.index ["book_id", "target_format"], name: "index_conversions_on_active_book_target", unique: true, where: "status IN ('pending', 'running')"
    t.index ["book_id"], name: "index_conversions_on_book_id"
  end

  create_table "deliveries", force: :cascade do |t|
    t.integer "book_id", null: false
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.integer "device_id", null: false
    t.string "evict_reason"
    t.datetime "evict_requested_at"
    t.datetime "removed_at"
    t.datetime "updated_at", null: false
    t.index ["book_id", "device_id"], name: "index_deliveries_on_book_id_and_device_id", unique: true
    t.index ["book_id"], name: "index_deliveries_on_book_id"
    t.index ["device_id", "evict_requested_at"], name: "index_deliveries_on_device_active", where: "removed_at IS NULL"
    t.index ["device_id"], name: "index_deliveries_on_device_id"
  end

  create_table "device_syncs", force: :cascade do |t|
    t.integer "battery_percent"
    t.datetime "created_at", null: false
    t.integer "device_id", null: false
    t.integer "downloaded_count", default: 0, null: false
    t.integer "duration_ms"
    t.integer "error_count", default: 0, null: false
    t.bigint "free_bytes"
    t.integer "removed_count", default: 0, null: false
    t.integer "sdr_applied_count", default: 0, null: false
    t.integer "sdr_pushed_count", default: 0, null: false
    t.index ["device_id", "created_at"], name: "index_device_syncs_on_device_id_and_created_at"
    t.index ["device_id"], name: "index_device_syncs_on_device_id"
  end

  create_table "devices", force: :cascade do |t|
    t.boolean "auto_evict", default: false, null: false
    t.integer "battery_percent"
    t.datetime "created_at", null: false
    t.boolean "experiments_frozen"
    t.string "firmware_version"
    t.bigint "free_bytes"
    t.boolean "freeze_experiments", default: true, null: false
    t.string "kind", default: "kindle", null: false
    t.string "kindled_version"
    t.datetime "last_seen_at"
    t.datetime "last_sync_at"
    t.integer "low_space_threshold_mb", default: 500, null: false
    t.boolean "modern_reader_pinned", default: true, null: false
    t.string "name", null: false
    t.string "reader_mode"
    t.datetime "reader_settings_applied_at"
    t.boolean "reader_writeback", default: false, null: false
    t.string "serial"
    t.datetime "status_reported_at"
    t.string "token_digest", null: false
    t.bigint "total_bytes"
    t.datetime "updated_at", null: false
    t.index ["kind"], name: "index_devices_on_kind"
    t.index ["token_digest"], name: "index_devices_on_token_digest", unique: true
  end

  create_table "import_files", force: :cascade do |t|
    t.integer "book_file_id"
    t.datetime "created_at", null: false
    t.string "message"
    t.datetime "mtime", null: false
    t.string "path", null: false
    t.string "sha256"
    t.bigint "size", null: false
    t.string "status", default: "imported", null: false
    t.datetime "updated_at", null: false
    t.index ["book_file_id"], name: "index_import_files_on_book_file_id"
    t.index ["path"], name: "index_import_files_on_path", unique: true
    t.index ["sha256"], name: "index_import_files_on_sha256"
    t.index ["status"], name: "index_import_files_on_status"
  end

  create_table "kosync_credentials", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key_digest", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.string "username", null: false
    t.index ["user_id"], name: "index_kosync_credentials_on_user_id"
    t.index ["username"], name: "index_kosync_credentials_on_username", unique: true
  end

  create_table "kosync_progresses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "device"
    t.string "device_id"
    t.string "document", null: false
    t.integer "kosync_credential_id", null: false
    t.text "metadata"
    t.float "percentage", null: false
    t.text "progress", null: false
    t.integer "synced_at", null: false
    t.datetime "updated_at", null: false
    t.index ["kosync_credential_id", "document"], name: "index_kosync_progresses_on_credential_and_document", unique: true
    t.index ["kosync_credential_id"], name: "index_kosync_progresses_on_kosync_credential_id"
  end

  create_table "reader_positions", force: :cascade do |t|
    t.integer "book_id", null: false
    t.text "cfi"
    t.text "context"
    t.datetime "created_at", null: false
    t.float "fraction"
    t.float "percent"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["book_id", "user_id"], name: "index_reader_positions_on_book_id_and_user_id", unique: true
    t.index ["book_id"], name: "index_reader_positions_on_book_id"
    t.index ["user_id"], name: "index_reader_positions_on_user_id"
  end

  create_table "reading_states", force: :cascade do |t|
    t.integer "annotation_count", default: 0, null: false
    t.integer "book_id", null: false
    t.datetime "content_mtime", null: false
    t.datetime "created_at", null: false
    t.integer "device_id", null: false
    t.integer "last_position"
    t.datetime "parsed_at"
    t.string "path", null: false
    t.float "progress_percent"
    t.string "progress_source"
    t.string "sha256", null: false
    t.text "sidecar_files"
    t.integer "size", null: false
    t.datetime "updated_at", null: false
    t.index ["book_id", "device_id"], name: "index_reading_states_on_book_id_and_device_id", unique: true
    t.index ["book_id"], name: "index_reading_states_on_book_id"
    t.index ["content_mtime"], name: "index_reading_states_on_content_mtime"
    t.index ["device_id"], name: "index_reading_states_on_device_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "admin", default: false, null: false
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "annotations", "books"
  add_foreign_key "annotations", "devices"
  add_foreign_key "book_files", "books"
  add_foreign_key "conversions", "book_files"
  add_foreign_key "conversions", "books"
  add_foreign_key "deliveries", "books"
  add_foreign_key "deliveries", "devices"
  add_foreign_key "device_syncs", "devices"
  add_foreign_key "import_files", "book_files", on_delete: :nullify
  add_foreign_key "kosync_credentials", "users"
  add_foreign_key "kosync_progresses", "kosync_credentials"
  add_foreign_key "reader_positions", "books"
  add_foreign_key "reader_positions", "users"
  add_foreign_key "reading_states", "books"
  add_foreign_key "reading_states", "devices"
  add_foreign_key "sessions", "users"
end
