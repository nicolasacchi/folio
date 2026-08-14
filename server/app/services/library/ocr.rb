# Thin wrapper around the ocrmypdf CLI, in the style of Calibre (see
# app/services/calibre.rb): .call shells out to a caller-chosen
# output_path and raises Library::Ocr::Error on failure. Writing that
# output into place and updating the book_file row is OcrBookJob's job
# (the way ConvertBookJob drives Calibre.convert) — #root/#path here just
# say *where* a book's OCR companion belongs, mirroring
# Library::KindlePrep.root / Library::Thumbnails.root, so OcrBookJob and
# Library::StorageGc agree on it.
#
# The source PDF is NEVER modified: ocrmypdf always writes to a distinct
# output_path, and --skip-text passes already-text pages through
# unchanged rather than re-rastering them.
module Library
  module Ocr
    class Error < StandardError; end

    # A big scanned book can legitimately take a long time under a single
    # worker thread (see config/queue.yml — :conversion is 1 thread/1
    # process on this host); this just stops a wedged/runaway ocrmypdf
    # process from blocking that queue forever. OcrBookJob's caller can
    # override per call.
    DEFAULT_TIMEOUT = 30 * 60 # seconds

    # book.language values observed in the library: bare ISO 639-1 (it,
    # en, es, de, fr, ru, pt, ar), ISO 639-2/T (ita, eng, spa, deu, fra,
    # rus, por, ara) — the tesseract package codes — plus blank/garbage
    # values Calibre's metadata couldn't clean up. Maps either form to the
    # tesseract-ocr-* language code installed in the image (see Dockerfile).
    ISO_TO_TESSERACT = {
      "ita" => "ita", "it" => "ita",
      "eng" => "eng", "en" => "eng",
      "spa" => "spa", "es" => "spa",
      "deu" => "deu", "de" => "deu",
      "fra" => "fra", "fr" => "fra",
      "rus" => "rus", "ru" => "rus",
      "por" => "por", "pt" => "por",
      "ara" => "ara", "ar" => "ara"
    }.freeze

    # The library is Italian-dominant, so blank/unrecognized language
    # falls back to Italian, not English.
    DEFAULT_LANGUAGE = "ita+eng"

    module_function

    # Regenerable OCR companions live in their own directory, one file per
    # book (like Library::KindlePrep.root's "prepared/" or
    # Library::Thumbnails.root), so Library::StorageGc can sweep orphans
    # the same way it already does for those.
    def root
      Library.base_root.join("ocr")
    end

    def path(book)
      root.join("#{book.public_id}.ocr.pdf")
    end

    # Tesseract language argument for a book: the mapped primary language,
    # plus "+eng" unless the primary already is English (tesseract tries
    # each listed language's dictionary/model in turn, so this catches
    # English front matter/captions in a foreign-language scan without
    # doubling up when the book is already English).
    def language_for(book)
      code = ISO_TO_TESSERACT[book.language.to_s.strip.downcase]
      return DEFAULT_LANGUAGE unless code

      code == "eng" ? "eng" : "#{code}+eng"
    end

    # Runs ocrmypdf source_path -> output_path, returning the extracted
    # sidecar text (read + stripped). Raises Error with the tail of
    # stderr (where ocrmypdf's actual failure reason lives, after any
    # verbose warm-up/warning lines) on a nonzero exit.
    def call(source_path, output_path, language: DEFAULT_LANGUAGE, timeout: DEFAULT_TIMEOUT)
      sidecar_path = "#{output_path}.sidecar.txt"

      command = [
        "timeout", "--signal=KILL", timeout.to_s,
        "ocrmypdf",
        "--skip-text", # pages that already have a text layer pass through untouched
        "-l", language,
        "--sidecar", sidecar_path,
        "--jobs", "1", # host is disk-constrained; keep OCR serialized (see config/queue.yml)
        "--optimize", "1",
        "--output-type", "pdf",
        "--quiet",
        source_path.to_s,
        output_path.to_s
      ]

      stdout, stderr, status = Open3.capture3(*command)
      unless status.success?
        raise Error, "ocrmypdf failed (#{status.exitstatus}): #{tail(stderr.presence || stdout)}"
      end

      File.read(sidecar_path, encoding: "UTF-8", invalid: :replace, undef: :replace).strip
    ensure
      FileUtils.rm_f(sidecar_path)
    end

    # Last N bytes of a shell command's output — ocrmypdf is chatty even
    # at low verbosity, and the line that actually explains a failure
    # tends to be near the end rather than the start (unlike Calibre.run,
    # which head-slices; see app/services/calibre.rb).
    def tail(text, limit = 4000)
      text = text.to_s
      text.byteslice([ text.bytesize - limit, 0 ].max, limit)
    end
  end
end
