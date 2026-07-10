# Extracts text from the best available file and (re)indexes the book in
# the FTS5 search table.
class IndexBookJob < ApplicationJob
  queue_as :default

  # Formats ranked by how clean their extracted text is.
  TEXT_SOURCE_PREFERENCE = %w[txt epub azw3 mobi azw fb2 docx html htmlz odt rtf lit pdf].freeze

  def perform(book_id)
    book = Book.find_by(id: book_id)
    return unless book

    BookSearch.index_book!(book, fulltext: extract_fulltext(book))
  end

  private

  def extract_fulltext(book)
    return nil unless Calibre.available?

    by_format = book.book_files.index_by(&:format)
    source = TEXT_SOURCE_PREFERENCE.filter_map { |format| by_format[format] }.first
    return nil unless source

    Calibre.extract_text(source.absolute_path).presence
  end
end
