# Full-text search over books, backed by an SQLite FTS5 virtual table.
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

  module_function

  def ensure_schema!
    connection.execute(SCHEMA_SQL)
  end

  def index_book!(book, fulltext: nil)
    fulltext ||= stored_fulltext(book.id)
    fulltext = fulltext.to_s.byteslice(0, MAX_FULLTEXT_BYTES).to_s.scrub("")
    remove_book!(book.id)
    connection.exec_query(
      "INSERT INTO book_search (book_id, title, author, series, description, fulltext) VALUES (?, ?, ?, ?, ?, ?)",
      "BookSearch Insert",
      [ book.id, book.title.to_s, book.author.to_s, book.series.to_s, book.description.to_s, fulltext ]
    )
  end

  def remove_book!(book_id)
    connection.exec_query("DELETE FROM book_search WHERE book_id = ?", "BookSearch Delete", [ book_id ])
  end

  # Returns [{ book_id:, snippet:, rank: }] ordered by relevance.
  def search(query, limit: 100)
    match = match_expression(query)
    return [] if match.blank?

    rows = connection.exec_query(<<~SQL, "BookSearch Query", [ match, limit ])
      SELECT book_id,
             snippet(book_search, 5, '<mark>', '</mark>', '…', 12) AS snippet,
             bm25(book_search, 0, 10.0, 8.0, 4.0, 2.0, 1.0) AS rank
      FROM book_search
      WHERE book_search MATCH ?
      ORDER BY rank
      LIMIT ?
    SQL
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
    connection.exec_query(
      "SELECT book_id FROM book_search WHERE length(fulltext) > 0", "BookSearch Fulltext Ids"
    ).rows.flatten
  end

  def stored_fulltext(book_id)
    row = connection.exec_query(
      "SELECT fulltext FROM book_search WHERE book_id = ?", "BookSearch Fulltext", [ book_id ]
    ).first
    row && row["fulltext"]
  end

  def connection
    ActiveRecord::Base.connection
  end
end
