# Full-text search over books, backed by an SQLite FTS5 virtual table in
# its own database file (like Library::Embeddings). Kept out of the
# primary database on purpose: bulk fulltext indexing holds the write
# lock for seconds per book, and with thousands of books queued that
# starved every other writer — device API calls were 500ing behind a
# catalog-wide indexing run.
#
# The table is populated explicitly (no triggers): call +index_book!+ after
# a book's metadata changes and +remove_book!+ on destroy. +fulltext+ holds
# text extracted from the best available file via Calibre.
module BookSearch
  SCHEMA_SQL = <<~SQL.freeze
    CREATE VIRTUAL TABLE IF NOT EXISTS book_search USING fts5(
      book_id UNINDEXED,
      title,
      author,
      series,
      description,
      fulltext,
      tokenize = 'unicode61 remove_diacritics 2'
    );
  SQL

  # Cap stored fulltext so a single huge book cannot bloat the index.
  MAX_FULLTEXT_BYTES = 2_000_000

  @mutex = Mutex.new

  module_function

  def db_path
    Pathname.new(ENV.fetch("BOOK_SEARCH_DB", Rails.root.join("storage", "#{Rails.env}_search.sqlite3").to_s))
  end

  def ensure_schema!
    with_db { nil }
  end

  def index_book!(book, fulltext: nil)
    fulltext ||= stored_fulltext(book.id)
    fulltext = fulltext.to_s.byteslice(0, MAX_FULLTEXT_BYTES).to_s.scrub("")
    with_db do |db|
      db.execute("DELETE FROM book_search WHERE book_id = ?", [ book.id ])
      db.execute(
        "INSERT INTO book_search (book_id, title, author, series, description, fulltext) VALUES (?, ?, ?, ?, ?, ?)",
        [ book.id, book.title.to_s, book.author.to_s, book.series.to_s, book.description.to_s, fulltext ]
      )
    end
  end

  def remove_book!(book_id)
    with_db { |db| db.execute("DELETE FROM book_search WHERE book_id = ?", [ book_id ]) }
  end

  # Returns [{ book_id:, snippet:, rank: }] ordered by relevance.
  def search(query, limit: 100)
    match = match_expression(query)
    return [] if match.blank?

    rows = with_db do |db|
      db.execute(<<~SQL, [ match, limit ])
        SELECT book_id,
               snippet(book_search, 5, '<mark>', '</mark>', '…', 12) AS snippet,
               bm25(book_search, 0, 10.0, 8.0, 4.0, 2.0, 1.0) AS rank
        FROM book_search
        WHERE book_search MATCH ?
        ORDER BY rank
        LIMIT ?
      SQL
    end
    rows.map { |row| { book_id: row["book_id"], snippet: row["snippet"], rank: row["rank"] } }
  end

  # Quote every term so user input cannot break FTS5 query syntax, and add
  # prefix matching to the last term for search-as-you-type friendliness.
  def match_expression(query)
    terms = query.to_s.scan(/[[:word:]]+/)
    return nil if terms.empty?

    terms.map.with_index do |term, index|
      index == terms.size - 1 ? "\"#{term}\"*" : "\"#{term}\""
    end.join(" ")
  end

  # Book ids whose index row already carries extracted text (used to size
  # and target the fulltext backfill).
  def book_ids_with_fulltext
    with_db do |db|
      db.execute("SELECT book_id FROM book_search WHERE length(fulltext) > 0").map { |row| row["book_id"] }
    end
  end

  def stored_fulltext(book_id)
    row = with_db { |db| db.execute("SELECT fulltext FROM book_search WHERE book_id = ?", [ book_id ]).first }
    row && row["fulltext"]
  end

  # One-time move of index rows out of the primary database, in batches so
  # concurrent indexing jobs are never locked out for long. Run via
  # `bin/rails book_search:migrate`. Idempotent: rows already present in
  # the dedicated file are skipped, and the legacy table is dropped at the
  # end (its ~GBs stay allocated until a manual VACUUM of the primary).
  def migrate_from_primary!(batch_size: 100)
    primary = ActiveRecord::Base.connection
    legacy = primary.select_value("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'book_search'")
    return 0 unless legacy

    moved = 0
    last_rowid = 0
    loop do
      rows = primary.exec_query(
        "SELECT rowid, book_id, title, author, series, description, fulltext
         FROM book_search WHERE rowid > ? ORDER BY rowid LIMIT ?",
        "BookSearch Legacy", [ last_rowid, batch_size ]
      ).to_a
      break if rows.empty?

      last_rowid = rows.last["rowid"]
      with_db do |db|
        db.transaction do
          rows.each do |row|
            next if db.get_first_value("SELECT 1 FROM book_search WHERE book_id = ?", [ row["book_id"] ])
            db.execute(
              "INSERT INTO book_search (book_id, title, author, series, description, fulltext) VALUES (?, ?, ?, ?, ?, ?)",
              row.values_at("book_id", "title", "author", "series", "description", "fulltext")
            )
            moved += 1
          end
        end
      end
    end

    primary.execute("DROP TABLE book_search")
    moved
  end

  # Test hooks.
  def clear!
    with_db { |db| db.execute("DELETE FROM book_search") }
  end

  def reset!
    @mutex.synchronize do
      @db&.close
      @db = nil
    end
  end

  def with_db
    @mutex.synchronize do
      @db ||= open_database
      yield @db
    end
  end

  def open_database
    FileUtils.mkdir_p(db_path.dirname)
    db = SQLite3::Database.new(db_path.to_s, results_as_hash: true)
    db.busy_timeout(15_000)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute(SCHEMA_SQL)
    db
  end
end
