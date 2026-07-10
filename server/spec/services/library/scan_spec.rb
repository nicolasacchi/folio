require 'rails_helper'

RSpec.describe Library::Scan do
  let(:root) { Pathname.new(Dir.mktmpdir("scan-root")) }

  after { FileUtils.rm_rf(root) }

  before do
    allow(Calibre).to receive(:metadata).and_return({})
    allow(Calibre).to receive(:extract_cover).and_return(false)
  end

  def write_calibre_book(dir_name, title:, formats: %w[epub], series: nil)
    dir = root.join("Author Name", dir_name)
    FileUtils.mkdir_p(dir)
    formats.each { |format| File.write(dir.join("#{dir_name}.#{format}"), "#{title} content as #{format}") }
    series_meta = series ? %(<meta content="#{series}" name="calibre:series"/>) : ""
    File.write(dir.join("metadata.opf"), <<~XML)
      <?xml version='1.0' encoding='utf-8'?>
      <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:title>#{title}</dc:title>
          <dc:creator>Author Name</dc:creator>
          #{series_meta}
        </metadata>
      </package>
    XML
    File.write(dir.join("cover.jpg"), "jpegbytes")
    dir
  end

  it "references Calibre-library books in place with sidecar metadata and covers" do
    write_calibre_book("The Salt Road (1)", title: "The Salt Road", formats: %w[epub mobi], series: "Roads")

    counts = described_class.call(roots: [ root ])

    expect(counts[:imported]).to eq(2)
    book = Book.find_by!(title: "The Salt Road")
    expect(book.author).to eq("Author Name")
    expect(book.series).to eq("Roads")
    expect(book.formats).to contain_exactly("epub", "mobi")
    expect(book.book_files).to all(have_attributes(source: "scan", available: true))
    expect(book.book_files.map(&:external?)).to all(be(true))
    expect(book.cover?).to be(true)
    # Files were referenced, not copied: nothing under the managed root.
    expect(Dir.exist?(Library.root.join(book.public_id))).to be(false)
  end

  it "groups loose same-stem files into one book and dedupes identical content" do
    loose = root.join("loose")
    FileUtils.mkdir_p(loose)
    File.write(loose.join("Winter Logbook -- Nora Keel.txt"), "winter text")
    File.write(loose.join("Winter Logbook -- Nora Keel.pdf"), "winter pdf")
    File.write(loose.join("copy of logbook.txt"), "winter text") # exact duplicate

    counts = described_class.call(roots: [ root ])

    expect(counts[:imported]).to eq(2)
    expect(counts[:duplicate]).to eq(1)
    book = Book.find_by!(title: "Winter Logbook")
    expect(book.author).to eq("Nora Keel")
    expect(book.formats).to contain_exactly("txt", "pdf")
    expect(ImportFile.find_by(path: loose.join("copy of logbook.txt").to_s).status).to eq("duplicate")
  end

  it "skips unchanged files on rescan via the ledger" do
    write_calibre_book("Book One (1)", title: "Book One")
    described_class.call(roots: [ root ])

    expect { @counts = described_class.call(roots: [ root ]) }.not_to change(Book, :count)
    expect(@counts[:imported]).to eq(0)
    expect(@counts[:unchanged]).to eq(1)
  end

  it "attaches a format added later to the existing book instead of duplicating it" do
    dir = write_calibre_book("Book Late (9)", title: "Book Late")
    described_class.call(roots: [ root ])
    File.write(dir.join("Book Late (9).mobi"), "late mobi content")

    expect { described_class.call(roots: [ root ]) }.not_to change(Book, :count)
    expect(Book.find_by!(title: "Book Late").formats).to contain_exactly("epub", "mobi")
  end

  it "flags files that disappear as missing and unavailable, and prunes them on request" do
    dir = write_calibre_book("Book Two (2)", title: "Book Two")
    described_class.call(roots: [ root ])
    book = Book.find_by!(title: "Book Two")

    FileUtils.rm_rf(dir)
    counts = described_class.call(roots: [ root ])

    expect(counts[:missing]).to eq(1)
    expect(book.book_files.reload.first.available).to be(false)
    expect(book.kindle_file).to be_nil

    expect(described_class.prune_missing!).to eq(1)
    expect(Book.exists?(book.id)).to be(false)
  end

  it "does not resurrect a book the user deleted" do
    write_calibre_book("Book Three (3)", title: "Book Three")
    described_class.call(roots: [ root ])
    book = Book.find_by!(title: "Book Three")
    source_file = book.book_files.first.absolute_path

    book.destroy!

    expect(File).to exist(source_file) # external files are never deleted
    expect { described_class.call(roots: [ root ]) }.not_to change(Book, :count)
    expect(ImportFile.find_by(path: source_file.to_s).status).to eq("removed")
  end
end
