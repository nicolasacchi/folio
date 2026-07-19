class LibraryScansController < ApplicationController
  def show
    @roots = Library::Scan.roots
    @progress = Library::Scan.progress
    @counts = ImportFile.group(:status).count
    @total = @counts.values.sum
    @problems = ImportFile.problems.order(updated_at: :desc).limit(50)

    @catalog = Rails.cache.fetch("catalog_counts", expires_in: 1.minute) do
      deliverable = BookFile.available.where(format: Book::KINDLE_FORMATS).distinct.count(:book_id)
      {
        books: Book.count,
        to_convert: Book.count - deliverable,
        fulltext_missing: Book.where(has_fulltext: false).count,
        duplicate_groups: Library::DuplicateGroups.count,
        to_enrich: Book.where(description: [ nil, "" ]).where(enriched_at: nil).count,
        embedded: Library::Embeddings.available? ? Library::Embeddings.count : nil,
        chunk_book_count: Library::Embeddings.available? ? Library::Embeddings.chunk_book_count : nil,
        queued: SolidQueue::Job.where(class_name: CatalogController::BATCH_JOB_CLASSES, finished_at: nil).count,
        failed_conversions: Conversion.where(status: "failed").count
      }
    end
    @catalog_progress = CatalogOperationJob.progress
  end

  def create
    ScanLibraryJob.perform_later
    redirect_to library_scan_path, notice: "Library scan queued."
  end

  def prune
    pruned = Library::Scan.prune_missing!
    redirect_to library_scan_path, notice: "Removed #{helpers.pluralize(pruned, 'missing file')} from the library."
  end
end
