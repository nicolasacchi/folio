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

ActiveRecord::Schema[8.1].define(version: 2026_07_10_150000) do
  create_table "book_files", force: :cascade do |t|
    t.boolean "available", default: true, null: false
    t.integer "book_id", null: false
    t.datetime "created_at", null: false
    t.string "format", null: false
    t.string "path", null: false
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
    t.datetime "created_at", null: false
    t.text "description"
    t.string "language"
    t.string "public_id", null: false
    t.integer "published_year"
    t.string "series"
    t.float "series_index"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["author"], name: "index_books_on_author"
    t.index ["created_at"], name: "index_books_on_created_at"
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
    t.index ["book_id"], name: "index_conversions_on_book_id"
  end

  create_table "devices", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_seen_at"
    t.string "name", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["token"], name: "index_devices_on_token", unique: true
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

  create_table "reading_states", force: :cascade do |t|
    t.integer "book_id", null: false
    t.datetime "content_mtime", null: false
    t.datetime "created_at", null: false
    t.integer "device_id", null: false
    t.string "path", null: false
    t.string "sha256", null: false
    t.integer "size", null: false
    t.datetime "updated_at", null: false
    t.index ["book_id", "device_id"], name: "index_reading_states_on_book_id_and_device_id", unique: true
    t.index ["book_id"], name: "index_reading_states_on_book_id"
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
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "book_files", "books"
  add_foreign_key "conversions", "book_files"
  add_foreign_key "conversions", "books"
  add_foreign_key "import_files", "book_files", on_delete: :nullify
  add_foreign_key "reading_states", "books"
  add_foreign_key "reading_states", "devices"
  add_foreign_key "sessions", "users"
end
