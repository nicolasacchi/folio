# Builds a minimal 2-page fixed-layout EPUB (rendition:layout pre-paginated)
# for the Playwright e2e suite — the fixed-layout counterpart to
# spec/support/epub_fixture.rb's reflowable EPUB, with the same hand-rolled
# stored-entry zip since the app has no zip gem. Distinct page colors/text
# make page turns observable in a browser.
module FxlEpub
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
        <dc:identifier id="bookid">urn:uuid:00000000-0000-0000-0000-0000000000e2</dc:identifier>
        <dc:title>E2E Fixed-Layout Book</dc:title>
        <dc:language>en</dc:language>
        <meta property="rendition:layout">pre-paginated</meta>
        <meta property="rendition:spread">none</meta>
      </metadata>
      <manifest>
        <item id="page1" href="page1.xhtml" media-type="application/xhtml+xml"/>
        <item id="page2" href="page2.xhtml" media-type="application/xhtml+xml"/>
      </manifest>
      <spine>
        <itemref idref="page1"/>
        <itemref idref="page2"/>
      </spine>
    </package>
  XML

  def self.page(body, color)
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
          <title>#{body}</title>
          <meta name="viewport" content="width=600, height=800"/>
        </head>
        <body style="margin:0">
          <div style="width:600px;height:800px;background:#{color};display:flex;align-items:center;justify-content:center">
            <h1>#{body}</h1>
          </div>
        </body>
      </html>
    XML
  end

  def entries
    [
      [ "mimetype", "application/epub+zip" ],
      [ "META-INF/container.xml", CONTAINER_XML ],
      [ "OEBPS/content.opf", CONTENT_OPF ],
      [ "OEBPS/page1.xhtml", page("E2E page one", "#f4e3c1") ],
      [ "OEBPS/page2.xhtml", page("E2E page two", "#c1d8f4") ]
    ]
  end

  def build
    local_parts = []
    central_parts = []
    offset = 0

    entries.each do |name, content|
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
      [ 0, 0, entries.size, entries.size, central_directory.bytesize, offset, 0 ].pack("vvvvVVv")

    (local_parts + [ central_directory, end_record ]).join
  end

  def write(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, build)
    path
  end
end
