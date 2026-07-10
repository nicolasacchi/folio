CREATE TABLE "schema_migrations" ("version" varchar NOT NULL PRIMARY KEY);
CREATE TABLE "ar_internal_metadata" ("key" varchar NOT NULL PRIMARY KEY, "value" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE TABLE "users" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "email_address" varchar NOT NULL, "password_digest" varchar NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE UNIQUE INDEX "index_users_on_email_address" ON "users" ("email_address") /*application='Server'*/;
CREATE TABLE "sessions" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "user_id" integer NOT NULL, "ip_address" varchar, "user_agent" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_758836b4f0"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE INDEX "index_sessions_on_user_id" ON "sessions" ("user_id") /*application='Server'*/;
CREATE TABLE "books" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "public_id" varchar NOT NULL, "title" varchar NOT NULL, "author" varchar, "series" varchar, "series_index" float, "language" varchar, "description" text, "published_year" integer, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE UNIQUE INDEX "index_books_on_public_id" ON "books" ("public_id") /*application='Server'*/;
CREATE TABLE "devices" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "name" varchar NOT NULL, "token" varchar NOT NULL, "last_seen_at" datetime(6), "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE UNIQUE INDEX "index_devices_on_token" ON "devices" ("token") /*application='Server'*/;
CREATE VIRTUAL TABLE book_search USING fts5(
  book_id UNINDEXED,
  title,
  author,
  series,
  description,
  fulltext,
  tokenize = 'unicode61 remove_diacritics 2'
)
/* book_search(book_id,title,author,series,description,fulltext) */;
CREATE TABLE 'book_search_data'(id INTEGER PRIMARY KEY, block BLOB);
CREATE TABLE 'book_search_idx'(segid, term, pgno, PRIMARY KEY(segid, term)) WITHOUT ROWID;
CREATE TABLE 'book_search_content'(id INTEGER PRIMARY KEY, c0, c1, c2, c3, c4, c5);
CREATE TABLE 'book_search_docsize'(id INTEGER PRIMARY KEY, sz BLOB);
CREATE TABLE 'book_search_config'(k PRIMARY KEY, v) WITHOUT ROWID;
CREATE TABLE "book_files" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "book_id" integer NOT NULL, "format" varchar NOT NULL, "path" varchar NOT NULL, "size" integer NOT NULL, "sha256" varchar NOT NULL, "source" varchar DEFAULT 'upload' NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_316133d0ef"
FOREIGN KEY ("book_id")
  REFERENCES "books" ("id")
);
CREATE INDEX "index_book_files_on_book_id" ON "book_files" ("book_id") /*application='Server'*/;
CREATE INDEX "index_book_files_on_sha256" ON "book_files" ("sha256") /*application='Server'*/;
CREATE UNIQUE INDEX "index_book_files_on_path" ON "book_files" ("path") /*application='Server'*/;
CREATE UNIQUE INDEX "index_book_files_on_book_id_and_format" ON "book_files" ("book_id", "format") /*application='Server'*/;
CREATE TABLE "reading_states" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "book_id" integer NOT NULL, "device_id" integer NOT NULL, "path" varchar NOT NULL, "content_mtime" datetime(6) NOT NULL, "size" integer NOT NULL, "sha256" varchar NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_ee7692f760"
FOREIGN KEY ("book_id")
  REFERENCES "books" ("id")
, CONSTRAINT "fk_rails_12e2254977"
FOREIGN KEY ("device_id")
  REFERENCES "devices" ("id")
);
CREATE INDEX "index_reading_states_on_book_id" ON "reading_states" ("book_id") /*application='Server'*/;
CREATE INDEX "index_reading_states_on_device_id" ON "reading_states" ("device_id") /*application='Server'*/;
CREATE UNIQUE INDEX "index_reading_states_on_book_id_and_device_id" ON "reading_states" ("book_id", "device_id") /*application='Server'*/;
CREATE TABLE "conversions" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "book_id" integer NOT NULL, "book_file_id" integer NOT NULL, "target_format" varchar NOT NULL, "status" varchar DEFAULT 'pending' NOT NULL, "error" text, "started_at" datetime(6), "finished_at" datetime(6), "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_f32d592c42"
FOREIGN KEY ("book_id")
  REFERENCES "books" ("id")
, CONSTRAINT "fk_rails_c3568e238f"
FOREIGN KEY ("book_file_id")
  REFERENCES "book_files" ("id")
);
CREATE INDEX "index_conversions_on_book_id" ON "conversions" ("book_id") /*application='Server'*/;
CREATE INDEX "index_conversions_on_book_file_id" ON "conversions" ("book_file_id") /*application='Server'*/;
INSERT INTO "schema_migrations" (version) VALUES
('20260710124551'),
('20260710124550'),
('20260710124549'),
('20260710124537'),
('20260710124535'),
('20260710124533'),
('20260710124439'),
('20260710124438');

