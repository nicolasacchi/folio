# Builds the Kindle-delivery copy of a book's deliverable file (see
# Library::KindlePrep). Queued when a book is sent to a device and
# whenever the manifest notices the copy is missing or stale. Runs on the
# conversion queue: cover embedding shells out to Calibre.
#
# ManifestsController#show re-enqueues this for every book that still
# needs_preparation? on every device poll (~30s), so several duplicates
# for the same book can pile up before the first finishes. The guard
# below already makes a duplicate a cheap no-op once the prepared copy
# is current; limits_concurrency stops duplicates from doing real work
# at the same time in the first place — at most one prep per book is
# ever in flight, DB-enforced regardless of worker topology.
class PrepareKindleFileJob < ApplicationJob
  queue_as :conversion
  limits_concurrency to: 1, key: ->(book_id) { "prepare-kindle-#{book_id}" }, duration: 10.minutes

  def perform(book_id)
    book = Book.find_by(id: book_id)
    return unless book

    file = book.kindle_file
    return unless file&.needs_preparation?

    Library::KindlePrep.prepare!(file)
  end
end
