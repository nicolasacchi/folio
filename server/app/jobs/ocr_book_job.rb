# Runs one queued OCR Conversion through Library::Ocr and records the
# resulting text-layer PDF as the source book_file's OCR companion —
# mirrors ConvertBookJob's shape, but the output isn't a new book_file
# (book_files has UNIQUE(book_id, format), and it's still a "pdf"): it's a
# regenerable companion tracked on the row itself (ocr_path/ocr_sha256/
# ocr_size/ocr_source_sha256), the same pattern Library::KindlePrep uses
# for prepared_path. The original PDF is never touched.
class OcrBookJob < ApplicationJob
  queue_as :ocr

  def perform(conversion_id)
    conversion = Conversion.find_by(id: conversion_id)
    return unless conversion&.pending?

    source = conversion.book_file
    book = conversion.book
    conversion.mark_running!

    dest = Library::Ocr.path(book)
    staging = Library::Ocr.root.join("staging-#{book.public_id}.ocr.pdf")
    FileUtils.mkdir_p(Library::Ocr.root)

    source_sha = source.sha256
    begin
      Library::Ocr.call(source.absolute_path, staging, language: Library::Ocr.language_for(book))
      File.rename(staging, dest)
    ensure
      FileUtils.rm_f(staging)
    end

    source.update!(
      ocr_path: dest.relative_path_from(Library.base_root).to_s,
      ocr_sha256: Library.sha256(dest),
      ocr_size: File.size(dest),
      ocr_source_sha256: source_sha
    )

    conversion.mark_completed!
    # Unlike ConvertBookJob (which skips this when the book already has
    # fulltext from some other format), an OCR run always gets a reindex:
    # it's the whole point of running it, and TEXT_SOURCE_PREFERENCE only
    # prefers the pdf source when nothing richer is available anyway, so
    # this is a cheap no-op re-extraction when it isn't the chosen source.
    # Runs on IndexBookJob's own :indexing queue (no override) — pinning it
    # onto :ocr or :conversion here is the anti-pattern that once starved
    # 8k indexing jobs behind heavy conversion work.
    IndexBookJob.perform_later(book.id)
    # A text companion (see Library::TextCompanion, TextCompanionJob) that
    # existed before this run was extracted from the *old* OCR text — the
    # ocr_sha256 update above just staled it (#text_fresh? compares
    # against #text_source_content_sha256, which now points at this new
    # OCR pass). Refresh it so the reader/Kindle text variant carries the
    # re-OCR forward instead of silently going stale. Reload first: `source`
    # was loaded once at the top of this (often long-running) job, so a
    # TextCompanionJob that wrote text_path concurrently wouldn't otherwise
    # be visible on this in-memory copy.
    source.reload
    book.queue_text_companion! if source.text_path.present? && !source.text_fresh?
  rescue Library::Ocr::Error => error
    conversion.mark_failed!(error.message)
  rescue StandardError => error
    # As with ConvertBookJob: not necessarily unrecoverable, so mark
    # failed (unwedging the active-conversion guards) but re-raise so
    # ActiveJob/SolidQueue still records and can retry the job.
    conversion&.mark_failed!(error.message)
    raise
  end
end
