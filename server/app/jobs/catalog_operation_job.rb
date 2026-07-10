# Whole-catalog batch operations, run one at a time on the scan queue so
# they never compete with each other or with folder scans. The heavy
# lifting still happens per book on the single-process conversion queue —
# this job only fans work out (or, for merges, walks the groups directly).
class CatalogOperationJob < ApplicationJob
  queue_as :scan
  limits_concurrency to: 1, key: "catalog_operation", duration: 12.hours

  PROGRESS_CACHE_KEY = "catalog_operation/progress"

  def self.progress
    Rails.cache.read(PROGRESS_CACHE_KEY)
  end

  def perform(operation)
    case operation.to_s
    when "convert_all" then convert_all
    when "index_fulltext" then index_fulltext
    when "merge_duplicates" then merge_duplicates
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

  # Queue Calibre text extraction for every book search can't see inside
  # yet — on the conversion queue, so it chews through serially instead of
  # saturating the box.
  def index_fulltext
    have = BookSearch.book_ids_with_fulltext
    queued = 0
    write_progress(operation: "index_fulltext", state: "running", queued: 0)
    Book.where.not(id: have).find_each do |book|
      IndexBookJob.set(queue: :conversion).perform_later(book.id)
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
    write_progress(operation: "merge_duplicates", state: "done", merged: merged, finished_at: Time.current.to_i)
  end

  def write_progress(**attributes)
    Rails.cache.write(PROGRESS_CACHE_KEY, attributes, expires_in: 2.days)
  end
end
