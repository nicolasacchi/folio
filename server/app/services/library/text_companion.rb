# Storage layout for a book's "text only" companion: a plain-text reflow
# of a pdf's (OCR'd) text for the web reader, plus the Kindle-ready AZW3
# Calibre builds from it. Like Library::Ocr, this module only says
# *where* things live (root/text_path/kindle_path) — TextCompanionJob does
# the actual extracting/converting and updates the source book_file's row
# (text_path/text_sha256/text_size/text_source_sha256, text_kindle_path/
# text_kindle_sha256/text_kindle_size), the way OcrBookJob drives
# Library::Ocr.
module Library
  module TextCompanion
    class Error < StandardError; end

    # pdftotext is fast (it reads the existing text layer rather than
    # re-rendering/OCRing pages), but a pathological pdf is still worth
    # capping rather than letting run forever — generous relative to the
    # OCR/Calibre timeouts since this is normally sub-second.
    DEFAULT_TIMEOUT = 300 # seconds

    # #deep_ocr_text's two phases, timed independently: rasterizing the
    # *whole* pdf with pdftoppm (one process, unbounded page count) needs a
    # generous whole-document ceiling, while each page's tesseract pass
    # (one process per page) only needs to survive a single wedged page —
    # a tight per-page timeout still lets the run recover partial output
    # from every other page instead of one runaway page burning the whole
    # budget.
    DEEP_RASTER_TIMEOUT = 900 # seconds, whole document
    DEEP_PAGE_TIMEOUT = 180 # seconds, one page

    module_function

    # One directory for both halves — Library::StorageGc sweeps it like
    # Library::Ocr.root/Library::KindlePrep.root.
    def root
      Library.base_root.join("text")
    end

    def text_path(book)
      root.join("#{book.public_id}.txt")
    end

    def kindle_path(book)
      root.join("#{book.public_id}.azw3")
    end

    # Extracts a book_file's plain text for the text-companion build (see
    # TextCompanionJob#build_text!). pdf gets pdftotext, which reads the
    # existing text layer straight out of the pdf structure — including an
    # OCR'd companion's text layer (#read_source_path already prefers that
    # over the raw scan) — near-instantly. ebook-convert's pdf pipeline
    # (Calibre.extract_text) instead re-renders every page, which on a
    # large image-heavy OCR'd scan can run to completion in name only:
    # minutes of work for 0 chars, because its pdf importer doesn't read
    # ocrmypdf's text layer the way pdftotext does. Every other format
    # still goes through Calibre — pdftotext only understands pdf, and
    # nothing else routes here today (Conversion's text-companion source is
    # gated to pdf), but this keeps the function total rather than raising
    # on a format it hasn't been asked to handle yet.
    def extract_text(book_file)
      case book_file.format
      when "pdf"
        extract_pdf_text(book_file.read_source_path)
      else
        Calibre.extract_text(book_file.read_source_path)
      end
    end

    # "Deep" re-OCR (see BookFile#text_engine, Book#queue_text_companion!,
    # BooksController#build_text): an opt-in, per-book rebuild for a
    # scanned pdf whose text (via ocrmypdf, see Library::Ocr, or the plain
    # #extract_text path above) came out wrong. docs/folio-ocr-engine-eval-
    # 2026-08.html found that on some scanned books ocrmypdf's --skip-text
    # leaves a *pre-existing, junk* legacy text layer in place untouched —
    # there's nothing for it to "skip" past, the pass-through itself is the
    # bug — and separately that ocrmypdf's own preprocessing (deskew/
    # despeckle/etc.) sometimes degrades recognition relative to running
    # tesseract directly against the untouched page raster. So this bypasses
    # ocrmypdf entirely: rasterize book_file.absolute_path — the RAW pdf,
    # deliberately not #read_source_path — because the whole point is
    # ignoring whatever text layer (junk or otherwise) the pdf already
    # carries, and the page *images* are identical either way (ocrmypdf
    # never touches pixels, only adds a text layer) — then OCR each page
    # image with plain tesseract.
    #
    # Slower than #extract_text by orders of magnitude (a full raster +
    # fresh per-page OCR vs. reading an existing text layer), which is why
    # it's a deliberate, per-book user action rather than a default.
    def deep_ocr_text(book_file)
      Dir.mktmpdir do |tmpdir|
        rasterize_pdf(book_file.absolute_path, tmpdir)

        pages = Dir.glob(File.join(tmpdir, "page*.png")).sort
        raise Error, "pdftoppm produced no page images for #{book_file.absolute_path}" if pages.empty?

        language = Library::Ocr.language_for(book_file.book)
        # Per-page rescue is the "tight per-page timeout" promise above
        # made real: one wedged/corrupt page raising (timeout or a
        # tesseract crash) only drops that page, not every other page's
        # already-successful OCR — logged and skipped rather than
        # aborting the whole (possibly hundred-page) rebuild.
        failures = []
        texts = pages.filter_map do |page|
          ocr_page(page, language: language)
        rescue Error => error
          Rails.logger.warn("deep OCR page failed for #{book_file.book.public_id}: #{error.message}")
          failures << error.message
          nil
        end
        # Every page failing (including the common single-page case) still
        # has nothing worth returning — raise with the underlying per-page
        # failure(s) rather than a generic message.
        raise Error, failures.join("; ") if texts.empty?

        scrub_utf8(texts.join("\n\n"))
      end
    end

    # Runs pdftotext source_path -> stdout, returning the extracted text.
    # Mirrors Library::Ocr.call's kill-timeout wrapper and array-form
    # Open3.capture3 invocation (see app/services/library/ocr.rb) — never
    # string-interpolated into a shell. Raises Error with the tail of
    # stderr (or stdout, if stderr is blank) on a nonzero exit.
    def extract_pdf_text(source_path, timeout: DEFAULT_TIMEOUT)
      command = [
        "timeout", "--signal=KILL", timeout.to_s,
        "pdftotext",
        "-enc", "UTF-8",
        "-nopgbrk", # no form-feed page breaks littering the reflow text
        source_path.to_s,
        "-" # stdout, not a sidecar file
      ]

      stdout, stderr, status = Open3.capture3(*command)
      unless status.success?
        raise Error, "pdftotext failed (#{status.exitstatus}): #{tail(stderr.presence || stdout)}"
      end

      scrub_utf8(stdout)
    end

    # Renders every page of source_path to grayscale 300dpi pngs under
    # tmpdir, named "page-N.png" (pdftoppm's own numbering — poppler pads
    # N with however many digits the last page needs, so a plain
    # lexicographic #sort on the resulting filenames already comes out in
    # page order). Grayscale because tesseract only ever recognizes on
    # luminance anyway; 300dpi is the resolution tesseract's own docs
    # recommend for reliable recognition. Raises Error with the tail of
    # stderr on a nonzero exit, mirroring #extract_pdf_text.
    def rasterize_pdf(source_path, tmpdir, timeout: DEEP_RASTER_TIMEOUT)
      command = [
        "timeout", "--signal=KILL", timeout.to_s,
        "pdftoppm",
        "-r", "300",
        "-gray",
        "-png",
        source_path.to_s,
        File.join(tmpdir, "page")
      ]

      _stdout, stderr, status = Open3.capture3(*command)
      unless status.success?
        raise Error, "pdftoppm failed (#{status.exitstatus}): #{tail(stderr)}"
      end
    end

    # Runs tesseract directly against one page png (no ocrmypdf in
    # between) and returns its stdout. "-l" takes the same per-book
    # language signal Library::Ocr.language_for already derives from
    # book.language (the "layer" path's OcrBookJob computes and passes
    # this too) — #deep_ocr_text is the only caller and passes it in,
    # defaulting here to Library::Ocr::DEFAULT_LANGUAGE ("ita+eng") only
    # for a caller with no book context. "--psm 3" (fully automatic page
    # segmentation, tesseract's own default) is deliberate: "--psm 6"
    # (assume a single uniform text block) was tried during the eval and
    # came out catastrophic on illustration-heavy scans, where tesseract
    # tried to read pictures as text instead of segmenting them out first.
    # Raises Error naming the failed page on a nonzero exit.
    def ocr_page(png_path, language: Library::Ocr::DEFAULT_LANGUAGE, timeout: DEEP_PAGE_TIMEOUT)
      command = [
        "timeout", "--signal=KILL", timeout.to_s,
        "tesseract", png_path, "stdout",
        "-l", language,
        "--psm", "3"
      ]

      stdout, stderr, status = Open3.capture3(*command)
      unless status.success?
        raise Error, "tesseract failed on #{File.basename(png_path)} (#{status.exitstatus}): #{tail(stderr.presence || stdout)}"
      end

      stdout
    end

    # Same invalid/undef replacement Calibre.extract_text applies via
    # File.read(..., invalid: :replace, undef: :replace) — stdout has no
    # file to read back, so this tags the bytes UTF-8 (pdftotext was told
    # -enc UTF-8) and re-encodes to itself, which is what actually forces
    # Ruby to validate and substitute invalid/undefined byte sequences.
    def scrub_utf8(text)
      text.dup.force_encoding("UTF-8").encode("UTF-8", invalid: :replace, undef: :replace)
    end

    # Last N bytes of a shell command's output, mirroring Library::Ocr.tail.
    def tail(text, limit = 4000)
      text = text.to_s
      text.byteslice([ text.bytesize - limit, 0 ].max, limit)
    end
  end
end
