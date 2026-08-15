# Extracts text from the best available file and (re)indexes the book in
# the FTS5 search table.
class IndexBookJob < ApplicationJob
  queue_as :indexing

  # Formats ranked by how clean their extracted text is.
  TEXT_SOURCE_PREFERENCE = %w[txt epub azw3 mobi azw prc fb2 docx html htmlz odt rtf lit pdf].freeze

  def perform(book_id)
    book = Book.find_by(id: book_id)
    return unless book

    # index_book! rewrites has_fulltext, so capture it before the call —
    # it's the only way to tell "fulltext just got cleared" from "this
    # book never had any" once the row has been overwritten.
    had_fulltext = book.has_fulltext
    # BookSearch.index_book!(fulltext: nil) falls back to whatever is
    # already stored (so a plain metadata reindex, or a transient Calibre
    # failure, never wipes a previous good extraction) — nil from
    # extract_fulltext must NOT reach it for a disabled book, or opting
    # out would silently keep serving the old text. "" bypasses that
    # fallback (it's truthy) and forces the clear opting out promises.
    BookSearch.index_book!(book, fulltext: book.fulltext_enabled? ? extract_fulltext(book) : "")
    # Chunk vectors are derived from stored fulltext: an opted-in book
    # needs (re)embedding, and a book whose fulltext was just removed
    # needs one run so index_book_chunks! sees the now-empty fulltext and
    # clears its stale chunk vectors. A book that was never opted in must
    # not churn the embeddings DB on every metadata reindex — a
    # catalog-wide metadata rebuild would otherwise fire ~29k no-op embed
    # jobs.
    EmbedBookChunksJob.perform_later(book.id) if Library::Embeddings.available? && (book.fulltext_enabled? || had_fulltext)
  end

  private

  def extract_fulltext(book)
    return nil unless book.fulltext_enabled?
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
