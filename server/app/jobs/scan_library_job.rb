# Runs the in-place folder scan (see Library::Scan). Lives on its own
# single-process queue so an hours-long first scan never starves uploads'
# indexing or conversions, and never runs twice concurrently.
class ScanLibraryJob < ApplicationJob
  queue_as :scan
  limits_concurrency to: 1, key: "library_scan", duration: 12.hours

  def perform
    Library::Scan.call
  end
end
