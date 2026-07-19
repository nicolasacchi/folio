# Acquisition-link `type=` values for OPDS entries — deliberately its own
# map rather than reusing ReaderController::MIME_TYPES (that one only
# covers Book::READABLE_FORMATS; OPDS acquisition links must offer every
# format in BookFile::FORMATS with a real MIME type, not just the ones the
# in-browser reader can open — see the implementation guide's rationale
# that OPDS clients filter/sort on `type=` and a bare octet-stream is a
# last resort, not the default).
module Opds
  module MimeTypes
    TABLE = {
      "epub"  => "application/epub+zip",
      "azw3"  => "application/x-mobipocket-ebook",
      "azw"   => "application/x-mobipocket-ebook",
      "mobi"  => "application/x-mobipocket-ebook",
      "prc"   => "application/x-mobipocket-ebook",
      "kfx"   => "application/x-mobipocket-ebook",
      "pdf"   => "application/pdf",
      "txt"   => "text/plain",
      "cbz"   => "application/vnd.comicbook+zip",
      "cbr"   => "application/x-cbr",
      "djvu"  => "image/vnd.djvu",
      "docx"  => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      "fb2"   => "application/x-fictionbook+xml",
      "html"  => "text/html",
      "htmlz" => "application/zip",
      "lit"   => "application/x-ms-reader",
      "odt"   => "application/vnd.oasis.opendocument.text",
      "rtf"   => "application/rtf"
    }.freeze

    module_function

    def for(format)
      TABLE.fetch(format, "application/octet-stream")
    end
  end
end
