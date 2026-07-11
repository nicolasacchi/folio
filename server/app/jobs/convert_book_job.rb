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
      Calibre.convert(source.absolute_path, target)
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
    # Keep Calibre-heavy work serialized on this queue: at batch-convert
    # scale, fulltext extraction on the 3-thread default queue would run
    # three ebook-converts in parallel on top of conversions.
    IndexBookJob.set(queue: :conversion).perform_later(book.id) unless had_fulltext
  rescue Calibre::Error, Library::Ingest::UnsupportedFormat => error
    conversion.mark_failed!(error.message)
  end
end
