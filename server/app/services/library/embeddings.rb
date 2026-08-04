# Book-level semantic vectors: one embedding per book over its title,
# author, series and description, produced fully locally (informers runs a
# multilingual MiniLM ONNX model baked into the image) and stored in a
# dedicated SQLite file with the sqlite-vec extension.
#
# Alongside that lives a second table, chunk_vec: overlapping windows of a
# book's *extracted fulltext* (see BookSearch), each embedded and stored
# separately. Metadata-only vectors can't find a concept buried on page 300
# of a 400-page book; chunk vectors can, at the cost of many rows per book
# instead of one. See #chunk_text and #index_book_chunks! below for the
# bounds that keep that cost sane over a catalog of thousands of books.
#
# The vector store deliberately lives outside the primary database so the
# ActiveRecord connection pool never needs the extension loaded; a single
# shared connection behind a mutex is plenty at this scale (~10k books,
# sub-millisecond KNN). Everything degrades gracefully when the model
# isn't present (development machines, tests): available? gates every
# caller.
module Library::Embeddings
  MODEL = "Xenova/paraphrase-multilingual-MiniLM-L12-v2"
  DIMENSIONS = 384

  # Target size of a chunk window. MiniLM's own context is ~256 subword
  # tokens; at roughly 4-6 characters/token for prose, ~1200 characters
  # sits near the top of what it can attend to without the pipeline's own
  # truncation silently dropping the tail of the chunk.
  CHUNK_TARGET_CHARS = 1200
  # ~15% overlap so a sentence that straddles a window boundary still
  # appears whole in at least one chunk.
  CHUNK_OVERLAP_RATIO = 0.15
  # How far back #chunk_text will look from a window's target end for a
  # paragraph break or plain whitespace, before giving up and cutting
  # mid-word. Small on purpose: a huge lookback could shrink a chunk a lot
  # chasing a boundary that isn't there.
  CHUNK_BOUNDARY_LOOKBACK = 80
  # A single pathological book (a bad OCR scan, a multi-volume omnibus)
  # could otherwise produce thousands of ~1200-char windows — embedding
  # all of them would dominate a catalog-wide backfill's runtime and
  # storage. #cap_chunks below samples MAX_CHUNKS_PER_BOOK windows evenly
  # across the whole text rather than just keeping the opening ones, so a
  # capped book still gets semantic reach into its middle and end.
  #
  # Storage/cost estimate at the cap: 240 chunks x (384 floats x 4 bytes +
  # a ~240-byte snippet) is under 500KB per book worst case; most books
  # (well under the cap) cost far less. Embedding itself is the same local
  # CPU work as book-level vectors, just up to 240x more calls per book,
  # which is why chunk indexing is a background job (EmbedBookChunksJob)
  # and full-catalog backfill is a separate, explicitly user-triggered
  # catalog operation rather than automatic.
  MAX_CHUNKS_PER_BOOK = 240
  # Truncated chunk text stored alongside its vector, shown as a "why this
  # result" preview in hybrid search results.
  SNIPPET_CHARS = 240
  # Bumped when any input to #chunk_content_fingerprint changes meaning
  # (window size, overlap, cap, model, dimensions, snippet length, …) so
  # existing book_chunk_meta rows are treated as stale and re-embedded.
  CHUNK_PARAMS_VERSION = 1
  # Chunks per embed() call. Bounds peak memory for a book that hits
  # MAX_CHUNKS_PER_BOOK without regressing to one embed() call per chunk
  # (slow — it's batching, not the total count, that keeps memory bounded).
  CHUNK_EMBED_BATCH_SIZE = 64
  # How many chunk rows to pull back from the KNN index per
  # #nearest_chunks call, relative to the number of *books* requested —
  # covers the worst case where several of the nearest chunks belong to
  # the same handful of books. Capped so a large `limit` can't turn into
  # an unbounded scan.
  CHUNK_OVERFETCH_MULTIPLIER = 6
  CHUNK_OVERFETCH_MAX = 300

  # Every process (Puma master, Solid Queue supervisor, each worker) opens
  # and uses only its own handle — see ForkSafeSqlite.
  extend ForkSafeSqlite

  @mutex = Mutex.new

  module_function

  def db_path
    Library.base_root.join("embeddings.sqlite3")
  end

  def available?
    return @available unless @available.nil?

    @available = !ENV["DISABLE_EMBEDDINGS"] && begin
      require "informers"
      true
    rescue LoadError
      false
    end
  end

  def embedder
    @embedder ||= begin
      require "informers"
      Informers.pipeline("embedding", MODEL)
    end
  end

  # texts -> arrays of DIMENSIONS floats (normalized by the pipeline).
  def embed(texts)
    embedder.(texts)
  end

  def text_for(book)
    text = [ book.title, book.author, book.series, book.description.to_s.byteslice(0, 1500).scrub("") ]
      .map { |part| part.to_s.strip }
      .reject(&:empty?)
      .join(". ")
    # Lightly biases nearest-neighbor results toward the same shelf without
    # requiring an exact category match (see docs/folio-library-categories-design.html#search).
    book.category.present? ? "[#{book.category}] #{text}" : text
  end

  def index_book!(book)
    index_books!([ book ])
  end

  def index_books!(books)
    return 0 if books.empty?

    vectors = embed(books.map { |book| text_for(book) })
    with_db do |db|
      books.zip(vectors).each do |book, vector|
        db.execute("DELETE FROM book_vec WHERE book_id = ?", [ book.id ])
        db.execute("INSERT INTO book_vec (book_id, embedding) VALUES (?, ?)",
                   [ book.id, vector.pack("f*") ])
      end
    end
    books.size
  end

  # Overlapping windows of ~CHUNK_TARGET_CHARS characters, splitting on a
  # paragraph break or whitespace rather than mid-word wherever one is
  # found within CHUNK_BOUNDARY_LOOKBACK characters of the target
  # boundary. Pure and model-independent: no DB, no embed() call, so it's
  # cheap to unit test directly.
  def chunk_text(text)
    normalized = text.to_s.strip
    return [] if normalized.empty?

    overlap = (CHUNK_TARGET_CHARS * CHUNK_OVERLAP_RATIO).round
    step = CHUNK_TARGET_CHARS - overlap
    length = normalized.length

    windows = []
    pos = 0
    while pos < length
      window_end = [ pos + CHUNK_TARGET_CHARS, length ].min
      window_end = boundary_before(normalized, window_end) if window_end < length

      windows << [ pos, window_end ]
      break if window_end >= length

      # boundary_before only ever moves window_end back by at most
      # CHUNK_BOUNDARY_LOOKBACK from pos + CHUNK_TARGET_CHARS, and
      # CHUNK_BOUNDARY_LOOKBACK < overlap's practical range here, so this
      # always advances — no infinite loop even on boundary-free text.
      # boundary_after then nudges the *next* chunk's start forward past
      # whatever word the raw overlap cut landed inside, so neither end of
      # a chunk boundary splits a word.
      pos = boundary_after(normalized, window_end - overlap, length)
    end

    chunks = windows.filter_map { |from, to| normalized[from...to].strip.presence }
    cap_chunks(chunks)
  end

  # Samples MAX_CHUNKS_PER_BOOK chunks evenly across the list rather than
  # truncating, so an over-cap book still gets coverage of its middle and
  # end, not just its opening. See the tradeoff note on MAX_CHUNKS_PER_BOOK.
  def cap_chunks(chunks)
    return chunks if chunks.size <= MAX_CHUNKS_PER_BOOK

    stride = chunks.size.fdiv(MAX_CHUNKS_PER_BOOK)
    Array.new(MAX_CHUNKS_PER_BOOK) { |i| chunks[(i * stride).floor] }
  end

  # Index of the best place at or before `idx` to end a chunk: a paragraph
  # break if one is nearby, else any whitespace, else `idx` itself (a
  # mid-word cut — only reached when a run of CHUNK_BOUNDARY_LOOKBACK+
  # characters has no whitespace at all).
  def boundary_before(text, idx)
    lookback_start = [ idx - CHUNK_BOUNDARY_LOOKBACK, 0 ].max
    window = text[lookback_start...idx]

    if (offset = window.rindex("\n\n"))
      return lookback_start + offset + 2
    end
    if (offset = window.rindex(/\s/))
      return lookback_start + offset + 1
    end

    idx
  end
  private_class_method :boundary_before

  # Mirror of boundary_before, looking forward: the best place at or after
  # `idx` to *start* the next chunk without beginning mid-word — the first
  # whitespace within CHUNK_BOUNDARY_LOOKBACK characters, or `idx` itself
  # if none is found.
  def boundary_after(text, idx, limit)
    lookahead_end = [ idx + CHUNK_BOUNDARY_LOOKBACK, limit ].min
    window = text[idx...lookahead_end]

    if (offset = window.index(/\s/))
      return idx + offset + 1
    end

    idx
  end
  private_class_method :boundary_after

  # Fingerprint of everything that would change a book's chunk vectors for
  # a given fulltext: model, dimensions, chunking params, and the text
  # itself. Pure — no DB. Used by #chunks_fresh? to skip re-embedding
  # when nothing has changed since the last successful index.
  def chunk_content_fingerprint(fulltext)
    Digest::SHA256.hexdigest(
      [
        "v#{CHUNK_PARAMS_VERSION}",
        MODEL,
        DIMENSIONS,
        CHUNK_TARGET_CHARS,
        CHUNK_OVERLAP_RATIO,
        CHUNK_BOUNDARY_LOOKBACK,
        MAX_CHUNKS_PER_BOOK,
        SNIPPET_CHARS,
        fulltext.to_s
      ].join("\0")
    )
  end

  def stored_chunk_fingerprint(book_id)
    with_db { |db| db.get_first_value("SELECT fingerprint FROM book_chunk_meta WHERE book_id = ?", [ book_id ]) }
  rescue SQLite3::Exception
    nil
  end

  def book_has_chunks?(book_id)
    with_db do |db|
      !db.get_first_value("SELECT 1 FROM chunk_vec WHERE book_id = ? LIMIT 1", [ book_id ]).nil?
    end
  rescue SQLite3::Exception
    false
  end

  def book_chunk_count(book_id)
    with_db { |db| db.get_first_value("SELECT count(*) FROM chunk_vec WHERE book_id = ?", [ book_id ]).to_i }
  rescue SQLite3::Exception
    0
  end

  # True when this book already has chunk vectors and their stored
  # fingerprint matches what we'd compute for `fulltext` under the
  # current model + chunk params — i.e. re-indexing would be a no-op.
  def chunks_fresh?(book_id, fulltext)
    stored = stored_chunk_fingerprint(book_id)
    stored.present? && stored == chunk_content_fingerprint(fulltext) && book_has_chunks?(book_id)
  end

  # (Re)indexes one book's chunk-level vectors from its extracted fulltext
  # (BookSearch's copy by default). Skips embed work when a stored
  # fingerprint still matches the current fulltext + chunk params
  # (#chunks_fresh?); pass force: true to re-embed anyway. On a real
  # write, deletes any existing chunks first so re-running (a
  # re-extraction, a param bump, force: true) replaces rather than
  # duplicates. Embeds in CHUNK_EMBED_BATCH_SIZE-sized batches — one
  # embed() call per batch, not per chunk.
  def index_book_chunks!(book, fulltext: nil, force: false)
    return 0 unless available?

    fulltext ||= BookSearch.stored_fulltext(book.id)
    fulltext_s = fulltext.to_s
    if fulltext_s.strip.empty?
      # No (more) extractable text — drop any stale chunks from a previous
      # version of this book's file, mirroring BookSearch's own handling
      # of an empty fulltext.
      remove_book_chunks!(book.id)
      return 0
    end

    unless force
      return book_chunk_count(book.id) if chunks_fresh?(book.id, fulltext_s)
    end

    chunks = chunk_text(fulltext_s)
    if chunks.empty?
      remove_book_chunks!(book.id)
      return 0
    end

    vectors = []
    chunks.each_slice(CHUNK_EMBED_BATCH_SIZE) { |batch| vectors.concat(embed(batch)) }

    fingerprint = chunk_content_fingerprint(fulltext_s)
    now = Time.now.to_i
    with_db do |db|
      db.transaction(:immediate) do
        db.execute("DELETE FROM chunk_vec WHERE book_id = ?", [ book.id ])
        chunks.each_with_index do |chunk, ord|
          db.execute(
            "INSERT INTO chunk_vec (book_id, chunk_ord, embedding, snippet) VALUES (?, ?, ?, ?)",
            [ book.id, ord, vectors[ord].pack("f*"), chunk.byteslice(0, SNIPPET_CHARS).to_s.scrub("") ]
          )
        end
        db.execute(
          "INSERT INTO book_chunk_meta (book_id, fingerprint, model, chunk_params_version, updated_at) " \
          "VALUES (?, ?, ?, ?, ?) " \
          "ON CONFLICT(book_id) DO UPDATE SET " \
          "fingerprint = excluded.fingerprint, model = excluded.model, " \
          "chunk_params_version = excluded.chunk_params_version, updated_at = excluded.updated_at",
          [ book.id, fingerprint, MODEL, CHUNK_PARAMS_VERSION, now ]
        )
      end
    end
    chunks.size
  end

  def remove_book_chunks!(book_id)
    with_db do |db|
      db.transaction(:immediate) do
        db.execute("DELETE FROM chunk_vec WHERE book_id = ?", [ book_id ])
        db.execute("DELETE FROM book_chunk_meta WHERE book_id = ?", [ book_id ])
      end
    end
  rescue SQLite3::Exception
    nil
  end

  def remove_book!(book_id)
    with_db do |db|
      db.transaction(:immediate) do
        db.execute("DELETE FROM book_vec WHERE book_id = ?", [ book_id ])
        db.execute("DELETE FROM chunk_vec WHERE book_id = ?", [ book_id ])
        db.execute("DELETE FROM book_chunk_meta WHERE book_id = ?", [ book_id ])
      end
    end
  rescue SQLite3::Exception
    nil
  end

  # Nearest books by cosine distance. Pass either a Book (uses its stored
  # vector, falling back to embedding its text) or a free-text query.
  # Returns [[book_id, distance], ...] nearest first.
  def nearest(book: nil, text: nil, limit: 12)
    query =
      if book
        stored = with_db { |db| db.get_first_value("SELECT embedding FROM book_vec WHERE book_id = ?", [ book.id ]) }
        stored || embed([ text_for(book) ]).first.pack("f*")
      else
        embed([ text.to_s ]).first.pack("f*")
      end

    rows = with_db do |db|
      db.execute(<<~SQL, [ query, limit + (book ? 1 : 0) ])
        SELECT book_id, distance FROM book_vec
        WHERE embedding MATCH ? AND k = ?
        ORDER BY distance
      SQL
    end
    rows = rows.reject { |id, _| id == book.id } if book
    rows.first(limit)
  end

  # Nearest books by their single best-matching chunk, aggregated from
  # chunk-level KNN. Returns [[book_id, distance, snippet], ...] nearest
  # first — distance is cosine distance (lower = more similar), same
  # convention as #nearest, so callers can treat the two interchangeably.
  # A book ranks by its *best* chunk, not how many of its chunks matched,
  # so a book with one great match beats one with several mediocre ones.
  def nearest_chunks(text:, limit: 12)
    return [] unless available?

    query = embed([ text.to_s ]).first.pack("f*")
    fetch = [ limit * CHUNK_OVERFETCH_MULTIPLIER, CHUNK_OVERFETCH_MAX ].min

    rows = with_db do |db|
      db.execute(<<~SQL, [ query, fetch ])
        SELECT book_id, snippet, distance FROM chunk_vec
        WHERE embedding MATCH ? AND k = ?
        ORDER BY distance
      SQL
    end

    best_by_book = {}
    rows.each do |book_id, snippet, distance|
      current = best_by_book[book_id]
      best_by_book[book_id] = [ distance, snippet ] if current.nil? || distance < current.first
    end

    best_by_book.map { |book_id, (distance, snippet)| [ book_id, distance, snippet ] }
                .sort_by { |_, distance, _| distance }
                .first(limit)
  end

  def count
    with_db { |db| db.get_first_value("SELECT count(*) FROM book_vec") }
  rescue SQLite3::Exception
    0
  end

  def chunk_count
    with_db { |db| db.get_first_value("SELECT count(*) FROM chunk_vec") }
  rescue SQLite3::Exception
    0
  end

  # Distinct books with at least one chunk vector — used to size the
  # chunk-level backfill button on the Catalog page.
  def chunk_book_count
    with_db { |db| db.get_first_value("SELECT count(DISTINCT book_id) FROM chunk_vec") }
  rescue SQLite3::Exception
    0
  end

  def open_database
    require "sqlite_vec"
    FileUtils.mkdir_p(db_path.dirname)
    db = SQLite3::Database.new(db_path.to_s)
    db.enable_load_extension(true)
    SqliteVec.load(db)
    db.enable_load_extension(false)
    db.busy_timeout(5_000)
    # WAL keeps the catalog page's counts readable while a batch re-embed
    # is writing.
    db.execute("PRAGMA journal_mode=WAL")
    db.execute(<<~SQL)
      CREATE VIRTUAL TABLE IF NOT EXISTS book_vec USING vec0(
        book_id integer PRIMARY KEY,
        embedding float[#{DIMENSIONS}] distance_metric=cosine
      )
    SQL
    # book_id is a many-per-book metadata column here (no PRIMARY KEY —
    # vec0 falls back to an implicit rowid), which is what makes
    # "DELETE ... WHERE book_id = ?" work without a MATCH clause: vec0
    # supports a plain filtered scan alongside its indexed KNN path.
    # snippet is an auxiliary (`+`) column: stored and returned, never
    # filtered or sorted on, which is exactly the "why this result"
    # preview text needs.
    db.execute(<<~SQL)
      CREATE VIRTUAL TABLE IF NOT EXISTS chunk_vec USING vec0(
        book_id integer,
        chunk_ord integer,
        embedding float[#{DIMENSIONS}] distance_metric=cosine,
        +snippet text
      )
    SQL
    # Fingerprint of the fulltext + chunk params that produced the current
    # chunk_vec rows for a book. Lets #index_book_chunks! skip re-embed
    # when nothing has changed (catalog-wide backfills, re-extractions
    # that produced identical text). Not a vec0 table — plain metadata.
    db.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS book_chunk_meta (
        book_id INTEGER PRIMARY KEY,
        fingerprint TEXT NOT NULL,
        model TEXT NOT NULL,
        chunk_params_version INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    SQL
    db
  end

  # Test hook: forget cached state (connection, model availability).
  def reset!
    @mutex.synchronize do
      @db&.close
      @db = nil
      @db_pid = nil
      @embedder = nil
      @available = nil
    end
  end
end
