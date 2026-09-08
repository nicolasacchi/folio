class UploadsController < ApplicationController
  # Uploaded Rack tempfiles are unlinked when the request ends, so each
  # file is first copied to a stable path here and ingested later by
  # IngestUploadJob — inline ingest (sha256 + an ebook-meta shell-out +
  # cover extraction per file) blocked the Puma worker for the whole batch.
  # tmp/ is gitignored and local to the app host; the job removes its
  # stashed copy when done.
  STASH_ROOT = Rails.root.join("tmp", "uploads")

  def new
  end

  def create
    files = Array(params[:files]).reject(&:blank?)
    return redirect_to new_upload_path, alert: "Pick at least one file." if files.empty?

    files.each do |upload|
      IngestUploadJob.perform_later(stash(upload).to_s, original_filename: upload.original_filename)
    end

    redirect_to root_path,
      notice: "#{helpers.pluralize(files.size, 'file')} #{files.one? ? 'is' : 'are'} being imported " \
              "in the background — each book appears on the shelf as it's processed."
  end

  private

  # The stash filename's extension matches the original's so a job that
  # ever fell back to its own path for format detection would still behave
  # (Ingest keys detection off original_filename regardless).
  def stash(upload)
    FileUtils.mkdir_p(STASH_ROOT)
    path = STASH_ROOT.join("#{SecureRandom.uuid}#{File.extname(upload.original_filename.to_s)}")
    FileUtils.cp(upload.tempfile.path, path)
    path
  end
end
