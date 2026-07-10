class LibraryScansController < ApplicationController
  def show
    @roots = Library::Scan.roots
    @progress = Library::Scan.progress
    @counts = ImportFile.group(:status).count
    @total = @counts.values.sum
    @problems = ImportFile.problems.order(updated_at: :desc).limit(50)
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
