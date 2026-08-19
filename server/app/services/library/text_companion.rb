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
  end
end
