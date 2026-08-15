# Runs one queued Conversion through ebook-convert and ingests the result
# as an additional file of the same book.
class ConvertBookJob < ApplicationJob
  queue_as :conversion

  def perform(conversion_id)
    conversion = Conversion.find_by(id: conversion_id)
    return unless conversion&.pending?

    source = conversion.book_file
    book = conversion.book
    conversion.mark_running!

    had_fulltext = BookSearch.stored_fulltext(book.id).present?

    Dir.mktmpdir("conversion") do |dir|
      target = File.join(dir, "#{Library.filename_stem(book)}.#{conversion.target_format}")
      # MOBI targets get the joint MOBI6+KF8 container: KF8 rendering for
      # the reader, MOBI6 outside so the Library UI shows the cover.
      options = conversion.target_format == "mobi" ? Library::KindlePrep::COMBO_OPTIONS : []
      # #read_source_path is the OCR companion (see Library::Ocr,
      # OcrBookJob) when one is fresh, else the raw file — only ever
      # differs for a pdf source, so converting an OCR'd pdf carries its
      # text layer into the derived epub/txt/etc. instead of starting from
      # the original scan's bare images.
      Calibre.convert(source.read_source_path, target, options: options)
      Library::Ingest.call(
        target,
        original_filename: File.basename(target),
        book: book,
        source: "converted",
        enqueue_followups: false
      )
    end

    conversion.mark_completed!
    # A queued-for-device book needs its delivery copy rebuilt from the
    # fresh file (cover + personal-document identity).
    PrepareKindleFileJob.perform_later(book.id) if book.deliveries.active.exists?
    # had_fulltext (captured above, before the conversion ran) is what
    # tells "still missing" apart from "already indexed" — only queue
    # extraction for a book that's actually opted in and doesn't have it
    # yet, or every conversion of every opted-out book (the common case,
    # since fulltext defaults off) would fire a pointless FTS write. Left
    # on IndexBookJob's own :indexing queue rather than forced onto
    # :conversion: pinning another job's queue here is the anti-pattern
    # that once stranded 8,498 jobs for eight days when that worker failed
    # to register (see CatalogOperationJob#index_fulltext) — and a
    # minutes-long extraction on this queue would block reader
    # auto-conversions and Kindle prep behind it.
    IndexBookJob.perform_later(book.id) if book.fulltext_enabled? && !had_fulltext
  rescue Calibre::Error, Library::Ingest::UnsupportedFormat => error
    conversion.mark_failed!(error.message)
  rescue StandardError => error
    # Unlike the two expected errors above, this file wasn't necessarily
    # unconvertible — leaving the conversion "running" would block every
    # future auto-retry (ensure_epub_conversion / ConversionsController
    # both skip while an active conversion exists). Mark it failed but
    # re-raise so ActiveJob/SolidQueue still records and can retry the job.
    conversion&.mark_failed!(error.message)
    raise
  end
end
