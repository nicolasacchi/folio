# Ingests one uploaded file the controller stashed under
# UploadsController::STASH_ROOT (see that controller for why uploads no
# longer ingest inline). One job per file so a batch of large PDFs costs a
# Puma worker nothing beyond the stash copy.
class IngestUploadJob < ApplicationJob
  queue_as :default

  def perform(stashed_path, original_filename:)
    result = Library::Ingest.call(stashed_path, original_filename: original_filename)
    Rails.logger.info("[ingest_upload] #{original_filename} already in the library — skipped") if result.duplicate?
  rescue Library::Ingest::UnsupportedFormat => error
    # Expected, non-retryable: the file's extension isn't a known book
    # format (or the target book already carries that format). The inline
    # path used to surface this in the post-upload flash; in the background
    # all we can do is log it.
    Rails.logger.warn("[ingest_upload] #{original_filename}: #{error.message}")
  rescue StandardError => error
    # Deliberately NOT re-raised: the stashed file is the only copy and is
    # removed either way (below), so a Solid Queue retry could only re-fail
    # with ENOENT — and the realistic failure modes (unreadable bytes,
    # Calibre choking on a corrupt file) are deterministic. The user can
    # re-upload; the log line carries the reason.
    Rails.logger.error("[ingest_upload] #{original_filename} failed: #{error.class}: #{error.message}")
  ensure
    FileUtils.rm_f(stashed_path)
  end
end
