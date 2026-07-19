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
      category,
      description,
      fulltext,
      tokenize = 'unicode61 remove_diacritics 2'
    );
  SQL

  # Cap stored fulltext so a single huge book cannot bloat the index.
  MAX_FULLTEXT_BYTES = 2_000_000

  # Every process (Puma master, Solid Queue supervisor, each worker) opens
  # and uses only its own handle — see ForkSafeSqlite.
  extend ForkSafeSqlite

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
      # DELETE+INSERT is a re-index, not two independent writes: without a
      # transaction, a crash (or a concurrent reader) between the two
      # statements could observe — or permanently leave — the book missing
      # from search. :immediate takes the write lock up front rather than
      # upgrading mid-transaction (see migrate_from_primary! above).
      db.transaction(:immediate) do
        db.execute("DELETE FROM book_search WHERE book_id = ?", [ book.id ])
        insert_row!(db, book, fulltext)
      end
    end
  end

  def remove_book!(book_id)
    with_db { |db| db.execute("DELETE FROM book_search WHERE book_id = ?", [ book_id ]) }
  end

  def insert_row!(db, book, fulltext)
    db.execute(
      "INSERT INTO book_search (book_id, title, author, series, category, description, fulltext) " \
      "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [ book.id, book.title.to_s, book.author.to_s, book.series.to_s, category_text_for(book), book.description.to_s,
        fulltext ]
    )
  end

  # The raw taxonomy key ("fiction/sf", which the tokenizer already splits
  # on "/" into "fiction" and "sf") plus its human labels ("Fiction",
  # "Fantascienza") so a shelf search works whichever one the user types.
  def category_text_for(book)
    category = book.category
    return "" if category.blank?

    [ category, Library::Taxonomy.label_for(category) ].join(" ")
  end

  # Returns [{ book_id:, snippet:, rank: }] ordered by relevance.
  # scope :metadata restricts matching to title/author/series (the default
  # search experience); :all also looks inside the description and the
  # extracted fulltext, and returns a highlighted snippet.
  def search(query, limit: 100, scope: :all)
    match = match_expression(query)
    return [] if match.blank?
    match = "{title author series category} : (#{match})" if scope == :metadata

    snippet_sql = scope == :metadata ? "NULL" : "snippet(book_search, 6, '<mark>', '</mark>', '…', 12)"
    rows = with_db do |db|
      db.execute(<<~SQL, [ match, limit ])
        SELECT book_id,
               #{snippet_sql} AS snippet,
               bm25(book_search, 0, 10.0, 8.0, 4.0, 3.0, 2.0, 1.0) AS rank
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
        # :immediate takes the write lock up front. A deferred transaction
        # would start as a read and get an instant (untimed) BUSY when it
        # tries to upgrade while indexing jobs are writing.
        db.transaction(:immediate) do
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
      @db_pid = nil
    end
  end

  def open_database
    FileUtils.mkdir_p(db_path.dirname)
    db = SQLite3::Database.new(db_path.to_s, results_as_hash: true)
    db.busy_timeout(15_000)
    db.execute("PRAGMA journal_mode=WAL")
    migrate_legacy_shape!(db)
    db.execute(SCHEMA_SQL)
    db
  end

  # fts5 virtual tables cannot ALTER TABLE ADD COLUMN, so a table created
  # before `category` existed is detected from its declared SQL in
  # sqlite_master (PRAGMA table_info reports fts5's internal bookkeeping
  # columns, not the ones this app declared) and rebuilt in place. The
  # copy stays entirely inside SQLite (INSERT..SELECT — the production
  # index is gigabytes of extracted fulltext, so pulling rows through
  # Ruby at boot both blocks the deploy and risks OOM); rows keep their
  # legacy metadata with a blank category, and index_book! refreshes
  # every book the next time it's touched (the post-deploy rescan calls
  # it for the whole curated tree).
  def migrate_legacy_shape!(db)
    return if db.get_first_value(
      "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'book_search'"
    ).then { |sql| sql.nil? || sql.include?("category") }

    # BEGIN IMMEDIATE serializes concurrent first-boot processes (Puma
    # workers, bin/jobs) on this shared file: whoever wins rebuilds, the
    # rest block on the write lock, then re-check and no-op. The re-check
    # inside the transaction is what makes the losers safe.
    db.transaction(:immediate) do
      declared_sql = db.get_first_value(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'book_search'"
      )
      next if declared_sql.nil? || declared_sql.include?("category")

      db.execute("DROP TABLE IF EXISTS book_search_migrating")
      db.execute(SCHEMA_SQL.sub("book_search", "book_search_migrating"))
      db.execute(<<~SQL)
        INSERT INTO book_search_migrating (book_id, title, author, series, category, description, fulltext)
        SELECT book_id, title, author, series, '', description, fulltext FROM book_search
      SQL
      db.execute("DROP TABLE book_search")
      db.execute("ALTER TABLE book_search_migrating RENAME TO book_search")
    end
  end
end
