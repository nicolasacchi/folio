# Extracts text from the best available file and (re)indexes the book in
# the FTS5 search table.
class IndexBookJob < ApplicationJob
  queue_as :indexing

  # Formats ranked by how clean their extracted text is.
  TEXT_SOURCE_PREFERENCE = %w[txt epub azw3 mobi azw prc fb2 docx html htmlz odt rtf lit pdf].freeze

  def perform(book_id)
    book = Book.find_by(id: book_id)
    return unless book

    BookSearch.index_book!(book, fulltext: extract_fulltext(book))
    # Chunk-level vectors are derived from the fulltext this job just
    # wrote, so keep them queued from the same place fulltext indexing
    # runs (uploads, the reindex button, the index_fulltext batch op) —
    # on their own :indexing-queue job so the (heavier) chunk embedding
    # never blocks fulltext extraction itself.
    EmbedBookChunksJob.perform_later(book.id) if Library::Embeddings.available?
  end

  private

  def extract_fulltext(book)
    return nil unless Calibre.available?

    by_format = book.book_files.index_by(&:format)
    source = TEXT_SOURCE_PREFERENCE.filter_map { |format| by_format[format] }.first
    return nil unless source

    # #read_source_path is the OCR companion (see Library::Ocr, OcrBookJob)
    # when one is fresh, else the raw file — only ever differs for a pdf
    # source, since only pdf book_files ever get an OCR companion. Simpler
    # than special-casing "pdf with a fresh companion" here, and it keeps
    # this extraction going through Calibre either way rather than trusting
    # the OCR sidecar text (which Calibre's own pdf conversion may clean up
    # differently).
    Calibre.extract_text(source.read_source_path).presence
  end
end
