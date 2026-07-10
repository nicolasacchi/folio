# Enriches one book from external catalogs. Lives on its own
# single-threaded queue, and sleeps after each network round-trip so the
# batch stays comfortably under the providers' politeness limits
# (~1 req/s) no matter how many books are queued.
class EnrichBookJob < ApplicationJob
  queue_as :enrichment

  def perform(book_id)
    book = Book.find_by(id: book_id)
    return unless book

    outcome = Library::Enrich.call(book)
    sleep 1.2 unless outcome == :skip
  end
end
