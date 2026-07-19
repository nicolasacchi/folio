# Binary endpoints an OPDS acquisition feed links to: the book file itself,
# its cover, and its Kindle-style thumbnail. Split out from CatalogController
# (which only ever renders XML) so the "serve bytes" concern stays separate
# from "build a feed" — mirrors the web split between BooksController#cover/
# #download and the Atom-only Opds::CatalogController.
module Opds
  class DownloadsController < BaseController
    before_action :set_book

    # Streams the raw file — the real EPUB/AZW3/PDF a Calibre-style OPDS
    # client expects, not the Kindle delivery/prepared copy the device API
    # and web #download default to (BookFile#delivery_path neutralizes the
    # store identity and is regenerated on demand; it's meaningless outside
    # the device pipeline). ?fmt= picks the format; omitted falls back to
    # the book's preferred Kindle-ready file, same default as
    # BooksController#download.
    def file
      book_file = params[:fmt].present? ? @book.file_for(params[:fmt]) : @book.kindle_file
      return head :not_found if book_file.nil? || !book_file.available? || !File.exist?(book_file.absolute_path)

      send_file book_file.absolute_path,
        filename: book_file.filename,
        type: Opds::MimeTypes.for(book_file.format),
        disposition: "attachment"
    end

    def cover
      return head :not_found unless @book.cover?

      fresh_when last_modified: File.mtime(@book.cover_path)
      return if request.fresh?(response)

      send_file @book.cover_path, type: "image/jpeg", disposition: "inline"
    end

    def thumbnail
      thumb = Library::Thumbnails.ensure(@book)
      return head :not_found unless thumb

      send_file thumb, type: "image/jpeg", disposition: "inline"
    end

    private

    # Scoped through available_books (>=1 deliverable file), same as every
    # feed entry — an OPDS client only ever gets a public_id from a feed we
    # produced, and a book with nothing deliverable was never listed there.
    def set_book
      @book = available_books.find_by!(public_id: params[:public_id])
    end
  end
end
