# Whole-catalog batch operations (fan-out happens in CatalogOperationJob;
# per-book work runs on the conversion queue). The buttons live on the
# Catalog (library scan) page.
class CatalogController < ApplicationController
  BATCH_JOB_CLASSES = %w[ConvertBookJob EnsureKindleFormatJob IndexBookJob CatalogOperationJob].freeze

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

    redirect_to library_scan_path, notice: "Cancelled #{helpers.pluralize(cancelled, 'queued job')}."
  end
end
