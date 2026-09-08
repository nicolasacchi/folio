# Folio — private library server

Rails 8 backend + phone-first web UI for the Kindle private cloud.
SQLite only (no external services): Solid Queue runs conversion jobs
inside Puma, FTS5 powers full-text search, Calibre does the ebook work.

## Requirements

- Ruby 3.3+, Bundler
- Calibre CLI tools on PATH (`ebook-convert`, `ebook-meta`)
- libvips
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
- **Folder scanning** (`Library::Scan`, Komga-style): point `SCAN_ROOTS`
  at existing ebook folders and scan from the Import page (plus a nightly
  recurring job). Files are *referenced in place* — never copied, moved
  or deleted — so a read-only mount works. Calibre-library layouts
  (`metadata.opf` + `cover.jpg`) supply metadata/covers without shelling
  out; loose files fall back to `ebook-meta`, grouping same-stem formats
  into one book. The `import_files` ledger makes rescans incremental
  (unchanged size+mtime → skipped), remembers deliberate deletes, flags
  vanished files as missing (with optional pruning), and records exact
  duplicates. Scanned books are search-indexed on metadata only; per-book
  "Index full text" opts into Calibre text extraction.
- **Conversion** (`ConvertBookJob`): `ebook-convert` on a single-threaded
  `conversion` queue; results are ingested as additional formats of the
  same book. Scans don't auto-convert (that would queue days of CPU for a
  large library) — convert per book from its page.
- **Search** (`BookSearch`): FTS5 virtual table over title, author,
  series, description and extracted fulltext; bm25-ranked with
  highlighted snippets. The table is created idempotently (see
  `config/initializers/book_search.rb`) because schema.rb cannot
  represent virtual tables.
- **Catalog operations** (`CatalogOperationJob`, buttons on the Catalog
  page): batch-convert everything to a Kindle format, batch full-text
  indexing, and merge-all-duplicates (each group folds into its best
  edition — most formats, then cover, then oldest; a conflicting external
  reference is dropped, ledger-remembered, and its file never touched).
  Fan-out runs on the scan queue, per-book work serializes on the
  conversion queue, and queued work is cancellable.
- **Enrichment** (`Library::Enrich`): fills only-blank descriptions,
  years and covers from Open Library (primary) and Google Books
  (fallback) behind a title/author plausibility check, throttled to
  ~1 lookup/s on its own queue; misses are remembered and never retried.
- **Semantic search** (`Library::Embeddings`): one vector per book
  (multilingual MiniLM ONNX via informers, model baked into the image;
  sqlite-vec store in `storage/embeddings.sqlite3`). Powers the
  "meaning" search toggle and the Similar-books shelf; vectors follow
  ingest/edit/enrich/destroy and a nightly batch re-embed.
- **Reading activity** (`/reading` + per-book section): populated from
  the `.sdr` bundles devices sync. `Library::SidecarProgress` inventories
  each bundle and best-effort parses MBP sidecars (last position,
  bookmarks, approximate percent); the bundle mtime is always a reliable
  last-read signal even when positions aren't parseable.
- **Device API** (`/api/v1`, token per device): manifest with
  reading-state summaries, file download by format, `.sdr` bundle
  GET/PUT with latest-mtime-wins. Consumed by `../kindled`. Only
  available (non-missing) files are offered.
- **Web UI**: Hotwire, plain CSS, installable PWA. Paginated library grid
  with sort (recent/title/author) and filters (format, author, series),
  series index, duplicate-editions page with merge, import status page,
  full-text search, uploads, per-book conversions with live status,
  device-token management.

## Deployment

`Dockerfile` builds a production image with Calibre included; Solid Queue
runs inside Puma (`SOLID_QUEUE_IN_PUMA=1`). A typical compose service
bind-mounts `storage/` for SQLite databases, covers, and uploads, and
optionally mounts an existing ebook folder read-only and points
`SCAN_ROOTS` at it. Set `SECRET_KEY_BASE`, `ADMIN_EMAIL`,
`ADMIN_PASSWORD`, and `APP_HOST`; optional SMTP_* enables password-reset
mail. `docker build --build-arg BUNDLE_WITHOUT="" -t folio:dev .` builds
the dev/test-gem variant used to run the spec suite:
`docker run --rm -v $PWD:/rails -e RAILS_ENV=test folio:dev bundle exec rspec`.

## Tests

```sh
bundle exec rspec
```
