# Builds the Kindle-delivery copy of a book's deliverable file (see
# Library::KindlePrep). Queued when a book is sent to a device and
# whenever the manifest notices the copy is missing or stale. Runs on the
# conversion queue: cover embedding shells out to Calibre.
class PrepareKindleFileJob < ApplicationJob
  queue_as :conversion

  def perform(book_id)
    book = Book.find_by(id: book_id)
    return unless book

    file = book.kindle_file
    return unless file&.needs_preparation?

    Library::KindlePrep.prepare!(file)
  end
end
