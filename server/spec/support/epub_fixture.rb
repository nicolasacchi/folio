# Builds a minimal-but-valid EPUB (a zip: mimetype + container.xml + an
# OPF package doc + one xhtml chapter) as raw bytes, hand-rolling the zip
# container (stored/uncompressed entries only) since the app has no zip
# gem in its Gemfile. Mirrors spec/support/mobi_fixture.rb's approach.
module EpubFixture
  module_function

  CONTAINER_XML = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
  XML

  CONTENT_OPF = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="bookid">urn:uuid:00000000-0000-0000-0000-000000000001</dc:identifier>
        <dc:title>Minimal Fixture</dc:title>
        <dc:language>en</dc:language>
      </metadata>
      <manifest>
        <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
      </manifest>
      <spine>
        <itemref idref="chapter1"/>
      </spine>
    </package>
  XML

  CHAPTER_XHTML = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml">
      <head><title>Chapter 1</title></head>
      <body><h1>Chapter 1</h1><p>Minimal fixture content for specs.</p></body>
    </html>
  XML

  ENTRIES = [
    [ "mimetype", "application/epub+zip" ],
    [ "META-INF/container.xml", CONTAINER_XML ],
    [ "OEBPS/content.opf", CONTENT_OPF ],
    [ "OEBPS/chapter1.xhtml", CHAPTER_XHTML ]
  ].freeze

  def build
    local_parts = []
    central_parts = []
    offset = 0

    ENTRIES.each do |name, content|
      crc = Zlib.crc32(content)
      size = content.bytesize

      local_header = "PK\x03\x04" +
        [ 20, 0, 0, 0, 0, crc, size, size, name.bytesize, 0 ].pack("vvvvvVVVvv")
      local_parts << local_header << name << content

      central_header = "PK\x01\x02" +
        [ 20, 20, 0, 0, 0, 0, crc, size, size, name.bytesize, 0, 0, 0, 0, 0o100644 << 16, offset ]
          .pack("vvvvvvVVVvvvvvVV")
      central_parts << central_header << name

      offset += local_header.bytesize + name.bytesize + content.bytesize
    end

    central_directory = central_parts.join
    end_record = "PK\x05\x06" +
      [ 0, 0, ENTRIES.size, ENTRIES.size, central_directory.bytesize, offset, 0 ].pack("vvvvVVv")

    (local_parts + [ central_directory, end_record ]).join
  end

  def write(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, build)
    path
  end
end
