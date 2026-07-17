require 'rails_helper'

RSpec.describe Library::Scan do
  let(:root) { Pathname.new(Dir.mktmpdir("scan-root")) }

  after { FileUtils.rm_rf(root) }

  before do
    allow(Calibre).to receive(:metadata).and_return({})
    allow(Calibre).to receive(:extract_cover).and_return(false)
  end

  # Nested under two lowercase category segments by default so the fixture
  # tree matches the real (post-migration) taxonomy layout; tests that care
  # about a specific category pass their own category_path.
  def write_calibre_book(dir_name, title:, formats: %w[epub], series: nil, category_path: %w[fiction general])
    dir = root.join(*category_path, "Author Name", dir_name)
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
    expect(book.category).to eq("fiction/general")
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

  it "prunes a missing file even when it sourced a conversion, without raising" do
    dir = write_calibre_book("Book Converted (4)", title: "Book Converted")
    described_class.call(roots: [ root ])
    book = Book.find_by!(title: "Book Converted")
    create(:conversion, book: book, book_file: book.book_files.first)

    FileUtils.rm_rf(dir)
    described_class.call(roots: [ root ])

    expect { described_class.prune_missing! }.not_to raise_error
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

  describe "category" do
    it "fills a blank category when a later-added format attaches to an existing book" do
      dir = write_calibre_book("Book Late (9)", title: "Book Late")
      described_class.call(roots: [ root ])
      Book.find_by!(title: "Book Late").update_columns(category: nil) # simulate a pre-feature row
      File.write(dir.join("Book Late (9).mobi"), "late mobi content")

      described_class.call(roots: [ root ])

      expect(Book.find_by!(title: "Book Late").category).to eq("fiction/general")
    end

    it "does not overwrite a manually edited category on an unchanged-file rescan" do
      write_calibre_book("Book One (1)", title: "Book One")
      described_class.call(roots: [ root ])
      book = Book.find_by!(title: "Book One")
      book.update!(category: "nonfiction/history")

      described_class.call(roots: [ root ]) # unchanged: ledger skip, must not touch category

      expect(book.reload.category).to eq("nonfiction/history")
    end
  end

  describe "relocation-aware rescan" do
    def create_device_and_annotate(book)
      device = create(:device)
      create(:annotation, book: book, device: device, content: "a highlighted passage")
    end

    it "repoints a broken book onto its content's new location, preserving the book and its annotations" do
      dir = write_calibre_book("Old Book", title: "Old Book", category_path: %w[fiction general])
      described_class.call(roots: [ root ])
      book = Book.find_by!(title: "Old Book")
      book_id = book.id
      annotation = create_device_and_annotate(book)
      old_path = book.book_files.first.path

      # The file disappears (library reorg in progress)...
      FileUtils.rm_rf(dir)
      counts = described_class.call(roots: [ root ])
      expect(counts[:missing]).to eq(1)
      expect(ImportFile.find_by(path: old_path).status).to eq("missing")

      # ...and the same content reappears under the new taxonomy path.
      new_dir = root.join("fiction", "sf", "Author Name", "Old Book")
      FileUtils.mkdir_p(new_dir)
      File.write(new_dir.join("Old Book.epub"), "Old Book content as epub") # identical bytes => identical sha256

      counts = described_class.call(roots: [ root ])

      expect(counts[:relocated]).to eq(1)
      book.reload
      expect(book.id).to eq(book_id)
      expect(book.category).to eq("fiction/sf")
      book_file = book.book_files.reload.first
      expect(book_file.path).to eq(new_dir.join("Old Book.epub").to_s)
      expect(book_file.available).to be(true)
      expect(book.annotations.reload).to contain_exactly(annotation)

      expect(ImportFile.find_by(path: old_path).status).to eq("removed")
      new_entry = ImportFile.find_by(path: book_file.path)
      expect(new_entry.status).to eq("imported")
      expect(new_entry.book_file_id).to eq(book_file.id)
    end

    it "repoints content whose old path is a hardlink outside the scan roots" do
      outside = Pathname.new(Dir.mktmpdir("scan-outside"))
      old_path = outside.join("Old Book.epub")
      File.write(old_path, "hardlinked content")
      book = create(:book, category: nil)
      create(:book_file, book: book, path: old_path.to_s, sha256: Digest::SHA256.file(old_path).hexdigest,
             size: File.size(old_path), source: "scan")

      new_dir = root.join("fiction", "sf", "Author Name", "Old Book")
      FileUtils.mkdir_p(new_dir)
      File.write(new_dir.join("Old Book.epub"), "hardlinked content")

      counts = described_class.call(roots: [ root ])

      expect(counts[:relocated]).to eq(1)
      book.reload
      expect(book.category).to eq("fiction/sf")
      expect(book.book_files.first.path).to eq(new_dir.join("Old Book.epub").to_s)
      expect(book.book_files.first.available).to be(true)
      expect(File).to exist(old_path) # the hardlink itself is never touched
    ensure
      FileUtils.rm_rf(outside)
    end
  end

  describe "hold dirs and noise files" do
    it "never imports anything under a top-level underscore dir except _inbox" do
      quarantine = root.join("_quarantine", "Author", "Dump")
      FileUtils.mkdir_p(quarantine)
      File.write(quarantine.join("Dump.epub"), "quarantined content")

      inbox = root.join("_inbox", "Loose")
      FileUtils.mkdir_p(inbox)
      File.write(inbox.join("Loose.epub"), "inbox content")

      described_class.call(roots: [ root ])

      expect(Book.exists?(title: "Dump")).to be(false)
      expect(ImportFile.exists?(path: quarantine.join("Dump.epub").to_s)).to be(false)
      book = Book.find_by!(title: "Loose")
      expect(book.category).to eq("_inbox")
    end

    it "skips hidden files (dotfiles) even when their extension is an importable format" do
      File.write(root.join(".migrate_sha256.txt"), "not a book")
      write_calibre_book("Book One (1)", title: "Book One")

      described_class.call(roots: [ root ])

      expect(ImportFile.exists?(path: root.join(".migrate_sha256.txt").to_s)).to be(false)
      expect(Book.count).to eq(1)
    end

    it "skips a README.* file sitting directly in a scan root" do
      File.write(root.join("README.txt"), "not a book")
      write_calibre_book("Book One (1)", title: "Book One")

      described_class.call(roots: [ root ])

      expect(ImportFile.exists?(path: root.join("README.txt").to_s)).to be(false)
      expect(Book.count).to eq(1)
    end
  end
end
