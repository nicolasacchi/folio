# Whole-catalog batch operations, run one at a time on the scan queue so
# they never compete with each other or with folder scans. The heavy
# lifting still happens per book on the single-process conversion queue —
# this job only fans work out (or, for merges, walks the groups directly).
class CatalogOperationJob < ApplicationJob
  queue_as :scan
  limits_concurrency to: 1, key: "catalog_operation", duration: 12.hours

  PROGRESS_CACHE_KEY = "catalog_operation/progress"

  # Books embedded per invocation before the job hands off to a fresh one.
  # Any single invocation must finish well inside
  # config.solid_queue.process_alive_threshold: a job that occupies its
  # worker for longer starves the heartbeat thread, gets pruned as dead and
  # is re-enqueued *from the beginning*, so a whole-catalog embed can loop
  # forever without ever completing a pass (it did — see embed_all).
  EMBED_BATCH_LIMIT = 2_000

  def self.progress
    Rails.cache.read(PROGRESS_CACHE_KEY)
  end

  def perform(operation, cursor = nil)
    case operation.to_s
    when "convert_all" then convert_all
    when "index_fulltext" then index_fulltext
    when "merge_duplicates" then merge_duplicates
    when "enrich_all" then enrich_all
    when "embed_all" then embed_all(cursor)
    when "embed_chunks_all" then embed_chunks_all
    else raise ArgumentError, "unknown catalog operation: #{operation}"
    end
  end

  private

  # Queue an AZW3 conversion for every book the Kindle can't open yet.
  # EnsureKindleFormatJob is idempotent (skips books that already have a
  # deliverable file or an active conversion), so re-running is safe.
  def convert_all
    queued = 0
    write_progress(operation: "convert_all", state: "running", queued: 0)
    Book.includes(:book_files).find_each do |book|
      next if book.kindle_file

      EnsureKindleFormatJob.perform_later(book.id)
      queued += 1
      write_progress(operation: "convert_all", state: "running", queued: queued) if (queued % 500).zero?
    end
    write_progress(operation: "convert_all", state: "done", queued: queued, finished_at: Time.current.to_i)
  end

  # Queue Calibre text extraction for every opted-in book search can't see
  # inside yet (fulltext is opt-in per book — see #reindex/#unindex on
  # BooksController). Leave these on IndexBookJob's own :indexing queue
  # (single process, so they still chew through serially instead of
  # saturating the box). Overriding the queue here once sent 8,498 jobs to
  # :conversion; when that worker later failed to register they sat
  # unclaimed for eight days while a third of the catalog stayed
  # unsearchable.
  def index_fulltext
    have = BookSearch.book_ids_with_fulltext
    queued = 0
    write_progress(operation: "index_fulltext", state: "running", queued: 0)
    Book.where(fulltext_enabled: true).where.not(id: have).find_each do |book|
      IndexBookJob.perform_later(book.id)
      queued += 1
      write_progress(operation: "index_fulltext", state: "running", queued: queued) if (queued % 500).zero?
    end
    write_progress(operation: "index_fulltext", state: "done", queued: queued, finished_at: Time.current.to_i)
  end

  # Merge every duplicate-editions group into its best edition (see
  # Library::DuplicateGroups.merge_target). Formats that would conflict
  # stay on their own book, so nothing is lost.
  def merge_duplicates
    merged = 0
    groups = Library::DuplicateGroups.tuples
    write_progress(operation: "merge_duplicates", state: "running", merged: 0, groups: groups.size)
    groups.each_with_index do |rows, index|
      books = Book.includes(:book_files).where(id: rows.map(&:first)).to_a
      next if books.size < 2

      target = Library::DuplicateGroups.merge_target(books)
      (books - [ target ]).each do |source|
        Library::MergeBooks.call(source, target)
        merged += 1
      end
      write_progress(operation: "merge_duplicates", state: "running", merged: merged, groups: groups.size) if (index % 50).zero?
    end
    write_progress(operation: "merge_duplicates", state: "done", merged: merged, groups: groups.size, finished_at: Time.current.to_i)
  end

  # Queue an external-catalog lookup for every book still missing
  # metadata that hasn't already come back empty-handed.
  def enrich_all
    queued = 0
    write_progress(operation: "enrich_all", state: "running", queued: 0)
    Book.where(description: [ nil, "" ]).where(enriched_at: nil).find_each do |book|
      EnrichBookJob.perform_later(book.id)
      queued += 1
      write_progress(operation: "enrich_all", state: "running", queued: queued) if (queued % 500).zero?
    end
    write_progress(operation: "enrich_all", state: "done", queued: queued, finished_at: Time.current.to_i)
  end

  # (Re)builds the semantic vector for every book, walking the catalog in
  # EMBED_BATCH_LIMIT-sized passes and handing off to a fresh job between
  # them. Each invocation is short enough to keep the worker's heartbeat
  # alive, and `cursor` (the last book id embedded) means a restart resumes
  # instead of starting the catalog over.
  def embed_all(cursor = nil)
    unless Library::Embeddings.available?
      write_progress(operation: "embed_all", state: "failed", error: "embedding model not available")
      return
    end

    embedded = cursor ? self.class.progress.to_h[:embedded].to_i : 0
    books = Book.order(:id).then { |scope| cursor ? scope.where("id > ?", cursor) : scope }
                .limit(EMBED_BATCH_LIMIT).to_a

    books.each_slice(64) do |slice|
      embedded += Library::Embeddings.index_books!(slice)
      write_progress(operation: "embed_all", state: "running", embedded: embedded, cursor: cursor)
    end

    if books.size < EMBED_BATCH_LIMIT
      write_progress(operation: "embed_all", state: "done", embedded: embedded, finished_at: Time.current.to_i)
    else
      next_cursor = books.last.id
      write_progress(operation: "embed_all", state: "running", embedded: embedded, cursor: next_cursor)
      self.class.perform_later("embed_all", next_cursor)
    end
  end

  # (Re)builds chunk-level vectors (see Library::Embeddings#index_book_chunks!)
  # for every book with extracted fulltext. Much heavier per book than
  # embed_all's single metadata vector — up to MAX_CHUNKS_PER_BOOK embed
  # calls instead of one — so over a real catalog this can run for a
  # while; it's why the backfill is its own explicitly user-triggered
  # button rather than something IndexBookJob fans out to automatically
  # for books already indexed before this feature existed.
  def embed_chunks_all
    unless Library::Embeddings.available?
      write_progress(operation: "embed_chunks_all", state: "failed", error: "embedding model not available")
      return
    end

    book_ids = BookSearch.book_ids_with_fulltext
    embedded = 0
    write_progress(operation: "embed_chunks_all", state: "running", embedded: 0, total: book_ids.size)
    Book.where(id: book_ids).find_each do |book|
      Library::Embeddings.index_book_chunks!(book)
      embedded += 1
      write_progress(operation: "embed_chunks_all", state: "running", embedded: embedded, total: book_ids.size) if (embedded % 100).zero?
    end
    write_progress(operation: "embed_chunks_all", state: "done", embedded: embedded, total: book_ids.size, finished_at: Time.current.to_i)
  end

  def write_progress(**attributes)
    Rails.cache.write(PROGRESS_CACHE_KEY, attributes, expires_in: 2.days)
  end
end
