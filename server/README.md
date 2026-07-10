# Folio — private library server

Rails 8 backend + phone-first web UI for the Kindle private cloud.
SQLite only (no external services): Solid Queue runs conversion jobs
inside Puma, FTS5 powers full-text search, Calibre does the ebook work.

## Requirements

- Ruby 3.3+, Bundler
- Calibre CLI tools on PATH (`ebook-convert`, `ebook-meta`)
- SQLite 3 (FTS5 is compiled into the stock library)

## Setup

```sh
bundle install
bin/rails db:prepare db:schema:load:queue
bin/rails db:seed          # prints the web login + first device token
bin/rails server           # Solid Queue runs inside Puma in development
```

Set `ADMIN_EMAIL` / `ADMIN_PASSWORD` before seeding to control the login.
Books, covers and reading-state bundles live under `storage/` (override
with `LIBRARY_ROOT`).

## How it fits together

- **Ingest** (`Library::Ingest`): sha256 dedupe, metadata + cover via
  `ebook-meta`, file stored under `storage/library/<public_id>/`, search
  indexing queued, and an automatic AZW3 conversion queued when the book
  has no Kindle-readable format (EPUB alone is not one).
- **Conversion** (`ConvertBookJob`): `ebook-convert` on a single-threaded
  `conversion` queue; results are ingested as additional formats of the
  same book.
- **Search** (`BookSearch`): FTS5 virtual table over title, author,
  series, description and extracted fulltext; bm25-ranked with
  highlighted snippets. The table is created idempotently (see
  `config/initializers/book_search.rb`) because schema.rb cannot
  represent virtual tables.
- **Device API** (`/api/v1`, token per device): manifest with
  reading-state summaries, file download by format, `.sdr` bundle
  GET/PUT with latest-mtime-wins. Consumed by `../kindled`.
- **Web UI**: Hotwire, plain CSS, installable PWA. Library grid,
  full-text search, uploads, per-book conversions with live status,
  device-token management.

## Tests

```sh
bundle exec rspec   # 42 examples
```
