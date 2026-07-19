# Whole-catalog batch operations (fan-out happens in CatalogOperationJob;
# per-book work runs on the conversion queue). The buttons live on the
# Catalog (library scan) page.
class CatalogController < ApplicationController
  BATCH_JOB_CLASSES = %w[ConvertBookJob EnsureKindleFormatJob IndexBookJob EnrichBookJob EmbedBookChunksJob CatalogOperationJob].freeze

  def convert_all
    CatalogOperationJob.perform_later("convert_all")
    redirect_to library_scan_path, notice: "Queuing a Kindle-format conversion for every book that needs one."
  end

  def index_fulltext
    CatalogOperationJob.perform_later("index_fulltext")
    redirect_to library_scan_path, notice: "Queuing full-text extraction for every book search can't see inside yet."
  end

  def merge_duplicates
    CatalogOperationJob.perform_later("merge_duplicates")
    redirect_to library_scan_path, notice: "Merging every duplicate-editions group into its best edition."
  end

  def enrich_all
    CatalogOperationJob.perform_later("enrich_all")
    redirect_to library_scan_path, notice: "Queuing metadata enrichment (Open Library / Google Books) for books missing a description."
  end

  def embed_all
    CatalogOperationJob.perform_later("embed_all")
    redirect_to library_scan_path, notice: "Rebuilding semantic vectors for the whole catalog."
  end

  def embed_chunks_all
    CatalogOperationJob.perform_later("embed_chunks_all")
    redirect_to library_scan_path, notice: "Building chunk-level semantic vectors for every book with full text — this powers meaning search inside a book, not just its metadata."
  end

  # Safety valve for the multi-day queues the buttons above can create.
  def cancel_queued
    cancelled = 0
    [ SolidQueue::ReadyExecution, SolidQueue::ScheduledExecution, SolidQueue::BlockedExecution ].each do |executions|
      executions.joins(:job)
                .where(solid_queue_jobs: { class_name: BATCH_JOB_CLASSES })
                .find_each do |execution|
        execution.job.destroy
        cancelled += 1
      end
    end
    # Pending conversions whose job was just cancelled would otherwise
    # block EnsureKindleFormatJob from ever retrying those books.
    Conversion.where(status: "pending").destroy_all
    # "Cancel queued work" is also the user's manual escape hatch for a
    # conversion wedged in "running" (its worker died without the periodic
    # sweep having caught it yet) — fail every currently-running conversion
    # immediately rather than waiting out STUCK_AFTER. If a worker is
    # actually still mid-run and later finishes, mark_completed! just flips
    # its (already-failed) row to completed; harmless.
    Conversion.sweep_stuck!(older_than: 0.seconds)

    redirect_to library_scan_path, notice: "Cancelled #{helpers.pluralize(cancelled, 'queued job')}."
  end
end
