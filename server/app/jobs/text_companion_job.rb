# Runs one queued "text only" Conversion: extracts the source pdf's
# (OCR'd, when fresh) text into a plain-text companion the web reader can
# open with the txt engine (see Library::TextCompanion), then builds a
# reflowable Kindle AZW3 from that text. Mirrors OcrBookJob's shape — the
# output isn't a new book_files row (see D1 in the design notes: a txt row
# would hijack readable_file/kindle_file's format ranking) but a
# regenerable companion tracked on the source row itself.
#
# engine (see BookFile#text_engine, Book#queue_text_companion!,
# BooksController#build_text) picks which of Library::TextCompanion's two
# extraction paths #build_text! uses: "layer" (the default — pdftotext off
# the pdf's own text layer) or "deep" (rasterize the raw scan and re-OCR it
# directly with tesseract, bypassing ocrmypdf). Defaulted to "layer" so
# already-enqueued jobs (serialized before this argument existed) keep
# calling #perform with one positional arg and behave exactly as before.
#
# The two halves fail independently: a blank/absurdly short extraction
# fails the whole conversion outright (nothing worth a companion), but a
# failed AZW3 build leaves the plain-text companion in place — the web
# reader still works even when Kindle delivery of the text variant
# doesn't (see #build_kindle_azw3!).
class TextCompanionJob < ApplicationJob
  queue_as :conversion

  # Library::TextCompanion.extract_text/.deep_ocr_text can return "" (the
  # non-pdf Calibre fallback, on total failure) or a near-empty string for
  # pdfs with nothing real to extract (a cover-only scan, a page OCR that
  # came back unreadable) — either way there's nothing worth a companion,
  # so this is the floor below which the conversion fails outright rather
  # than storing one nobody can read.
  MIN_TEXT_LENGTH = 200

  def perform(conversion_id, engine = "layer")
    conversion = Conversion.find_by(id: conversion_id)
    return unless conversion&.pending?

    source = conversion.book_file
    book = conversion.book
    conversion.mark_running!

    # Captured now (mirrors OcrBookJob's source_sha) so the row this job
    # writes always matches the bytes it actually read, even if a
    # concurrent re-OCR changes #text_source_content_sha256 mid-run.
    source_content_sha = source.text_source_content_sha256(engine)

    FileUtils.mkdir_p(Library::TextCompanion.root)
    build_text!(source, book, source_content_sha, engine)
    build_kindle_azw3!(source, book)

    conversion.mark_completed!
    # Cheap no-op unless this book's fulltext actually prefers a txt
    # source (see IndexBookJob::TEXT_SOURCE_PREFERENCE) — same "always
    # reindex, harmless when it isn't the chosen source" reasoning
    # OcrBookJob uses for its own always-reindex.
    IndexBookJob.perform_later(book.id)
  rescue Calibre::Error, Library::TextCompanion::Error => error
    conversion.mark_failed!(error.message)
  rescue StandardError => error
    # Not necessarily unrecoverable (mirrors ConvertBookJob/OcrBookJob):
    # mark failed so the active-conversion guards unwedge, but re-raise so
    # ActiveJob/SolidQueue still records and can retry.
    conversion&.mark_failed!(error.message)
    raise
  end

  private

  def build_text!(source, book, source_content_sha, engine)
    text = engine == "deep" ? Library::TextCompanion.deep_ocr_text(source) : Library::TextCompanion.extract_text(source)
    if text.strip.length < MIN_TEXT_LENGTH
      raise Library::TextCompanion::Error,
        "extracted text too short (#{text.strip.length} chars) to build a usable text version"
    end

    # Extraction happens (and is length-checked) entirely above, before
    # anything on disk or on the row changes — a failure here (either
    # raise) leaves any existing companion + its stamps (including
    # text_engine) completely untouched, so a bad deep-OCR attempt never
    # clobbers a good "layer" companion still fresh in its place.
    dest = Library::TextCompanion.text_path(book)
    staging = Library::TextCompanion.root.join("staging-#{book.public_id}.txt")
    begin
      File.write(staging, text, encoding: "UTF-8")
      File.rename(staging, dest)
    ensure
      FileUtils.rm_f(staging)
    end

    source.update!(
      text_path: dest.relative_path_from(Library.base_root).to_s,
      text_sha256: Library.sha256(dest),
      text_size: File.size(dest),
      text_source_sha256: source_content_sha,
      text_engine: engine
    )
  end

  # Calibre stamps EXTH 501="EBOK" plus a random calibre-uuid ASIN on
  # every azw3 it builds, this one included — so it needs the same
  # Library::KindlePrep pass a prepared book file gets (see that module's
  # doc for why: Kindle firmware treats EBOK content as a store book and
  # never extracts its embedded cover, only a "no image available"
  # placeholder). Patched here, on the staging file, before the rename —
  # #neutralize_store_identity! is KindlePrep's own path-based entry
  # point, so both flows share the byte-patching logic. The cover itself
  # is embedded at build time via --cover below (unlike ConvertBookJob's
  # plain formats, this source is a bare .txt with no embedded metadata of
  # its own, so title/authors/cover have to be passed explicitly rather
  # than carried over from the source file).
  def build_kindle_azw3!(source, book)
    dest = Library::TextCompanion.kindle_path(book)
    staging = Library::TextCompanion.root.join("staging-#{book.public_id}.azw3")
    options = [ "--title", book.title ]
    options += [ "--authors", book.author ] if book.author.present?
    options += [ "--cover", Library.cover_path(book).to_s ] if book.cover?

    Calibre.convert(source.text_absolute_path, staging, options: options)
    Library::KindlePrep.neutralize_store_identity!(staging)
    File.rename(staging, dest)

    # Stamped from the renamed file, after the patch above changed its
    # bytes — text_kindle_sha256 has to match what's actually served.
    source.update!(
      text_kindle_path: dest.relative_path_from(Library.base_root).to_s,
      text_kindle_sha256: Library.sha256(dest),
      text_kindle_size: File.size(dest)
    )
  rescue Calibre::Error
    # Keep the plain-text companion (already saved above by build_text!) —
    # only the Kindle-specific half failed. Cleared, not left stale,
    # because a stale text_kindle_path would otherwise still look usable
    # via BookFile#text_kindle_usable?.
    source.update!(text_kindle_path: nil, text_kindle_sha256: nil, text_kindle_size: nil)
    raise
  ensure
    FileUtils.rm_f(staging)
  end
end
