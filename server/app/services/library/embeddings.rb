# Book-level semantic vectors: one embedding per book over its title,
# author, series and description, produced fully locally (informers runs a
# multilingual MiniLM ONNX model baked into the image) and stored in a
# dedicated SQLite file with the sqlite-vec extension.
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
    [ book.title, book.author, book.series, book.description.to_s.byteslice(0, 1500).scrub("") ]
      .map { |part| part.to_s.strip }
      .reject(&:empty?)
      .join(". ")
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

  def remove_book!(book_id)
    with_db { |db| db.execute("DELETE FROM book_vec WHERE book_id = ?", [ book_id ]) }
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

  def count
    with_db { |db| db.get_first_value("SELECT count(*) FROM book_vec") }
  rescue SQLite3::Exception
    0
  end

  def with_db(&block)
    @mutex.synchronize do
      @db ||= open_database
      block.call(@db)
    end
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
    db
  end

  # Test hook: forget cached state (connection, model availability).
  def reset!
    @mutex.synchronize do
      @db&.close
      @db = nil
      @embedder = nil
      @available = nil
    end
  end
end
