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
