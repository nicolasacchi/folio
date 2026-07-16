require 'rails_helper'

RSpec.describe Library::Ingest do
  let(:source) { file_fixture("The Salt Road -- Ada Author.txt") }

  before do
    # Calibre integration is covered by manual smoke tests; keep specs fast
    # and deterministic.
    allow(Calibre).to receive(:metadata).and_return({})
    allow(Calibre).to receive(:extract_cover).and_return(false)
  end

  describe ".call" do
    it "creates a book with metadata parsed from the filename" do
      result = described_class.call(source, original_filename: source.basename.to_s)

      expect(result.duplicate?).to be(false)
      expect(result.book.title).to eq("The Salt Road")
      expect(result.book.author).to eq("Ada Author")
      expect(result.book_file.format).to eq("txt")
      expect(File).to exist(result.book_file.absolute_path)
      expect(result.book_file.sha256).to eq(Digest::SHA256.file(source).hexdigest)
    end

    it "enqueues search indexing" do
      expect { described_class.call(source, original_filename: source.basename.to_s) }
        .to have_enqueued_job(IndexBookJob)
    end

    context "when the same content was already ingested" do
      let!(:first) { described_class.call(source, original_filename: source.basename.to_s) }

      it "returns the existing book instead of duplicating it" do
        result = described_class.call(source, original_filename: "renamed.txt")

        expect(result.duplicate?).to be(true)
        expect(result.book).to eq(first.book)
        expect(Book.count).to eq(1)
      end
    end

    context "when the book has no Kindle-ready file" do
      it "enqueues an automatic Kindle conversion for an epub" do
        epub = Rails.root.join("tmp", "ingest-spec.epub")
        FileUtils.cp(source, epub)

        expect { described_class.call(epub, original_filename: "Some Novel.epub") }
          .to have_enqueued_job(EnsureKindleFormatJob)
      ensure
        FileUtils.rm_f(epub)
      end

      it "does not enqueue a conversion for a txt (already Kindle-readable)" do
        expect { described_class.call(source, original_filename: source.basename.to_s) }
          .not_to have_enqueued_job(EnsureKindleFormatJob)
      end
    end

    it "ignores a Calibre title that merely echoes the source file name" do
      tmp = Rails.root.join("tmp", "RackMultipart-xyz123.txt")
      FileUtils.cp(source, tmp)
      allow(Calibre).to receive(:metadata).and_return({ title: "RackMultipart-xyz123" })

      result = described_class.call(tmp, original_filename: "Winter Logbooks -- Nora Keel.txt")

      expect(result.book.title).to eq("Winter Logbooks")
      expect(result.book.author).to eq("Nora Keel")
    ensure
      FileUtils.rm_f(tmp)
    end

    it "rejects unsupported extensions" do
      expect { described_class.call(source, original_filename: "notes.xyz") }
        .to raise_error(Library::Ingest::UnsupportedFormat, /xyz/)
    end
  end

  describe "category" do
    it "sets category on a newly created book" do
      result = described_class.call(source, original_filename: source.basename.to_s, category: "fiction/sf")
      expect(result.book.category).to eq("fiction/sf")
    end

    it "fills category on an existing book only when blank" do
      book = create(:book, category: nil)
      described_class.call(source, original_filename: source.basename.to_s, book: book, category: "fiction/sf")
      expect(book.reload.category).to eq("fiction/sf")
    end

    it "does not overwrite an existing book's category" do
      book = create(:book, category: "fiction/literary")
      described_class.call(source, original_filename: source.basename.to_s, book: book, category: "fiction/sf")
      expect(book.reload.category).to eq("fiction/literary")
    end
  end

  describe "relocation (mode: :reference with scan_roots)" do
    let(:root) { Pathname.new(Dir.mktmpdir("ingest-relocate-root")) }
    let(:outside) { Pathname.new(Dir.mktmpdir("ingest-relocate-outside")) }

    after do
      FileUtils.rm_rf(root)
      FileUtils.rm_rf(outside)
    end

    def write(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end

    it "repoints a row whose file went missing instead of recording a duplicate, preserving the book and its associations" do
      old_path = outside.join("Old Book.epub")
      write(old_path, "same content")
      sha = Digest::SHA256.file(old_path).hexdigest
      book = create(:book, category: nil)
      stale = create(:book_file, book: book, path: old_path.to_s, sha256: sha, size: File.size(old_path),
                     source: "scan")
      annotation = create(:annotation, book: book)
      FileUtils.rm_f(old_path) # file vanished (moved on disk)

      new_path = root.join("fiction", "sf", "Author", "Old Book.epub")
      write(new_path, "same content")

      result = described_class.call(new_path, original_filename: "Old Book.epub", source: "scan",
                                     enqueue_followups: false, mode: :reference, category: "fiction/sf",
                                     scan_roots: [ root ])

      expect(result.relocated?).to be(true)
      expect(result.duplicate?).to be(false)
      expect(result.book_file).to eq(stale)
      expect(stale.reload.path).to eq(new_path.to_s)
      expect(stale.available).to be(true)
      expect(stale.source).to eq("scan")
      expect(result.book).to eq(book)
      expect(book.reload.category).to eq("fiction/sf")
      expect(book.annotations.reload).to contain_exactly(annotation)
    end

    it "marks the old path's ImportFile ledger entry removed and points at the new path" do
      old_path = outside.join("Old Book.epub")
      write(old_path, "same content")
      sha = Digest::SHA256.file(old_path).hexdigest
      book = create(:book)
      stale = create(:book_file, book: book, path: old_path.to_s, sha256: sha, size: File.size(old_path),
                     source: "scan")
      ImportFile.create!(path: old_path.to_s, size: stale.size, mtime: Time.current, status: "imported",
                          sha256: sha, book_file: stale)
      FileUtils.rm_f(old_path)

      new_path = root.join("fiction", "sf", "Author", "Old Book.epub")
      write(new_path, "same content")

      described_class.call(new_path, original_filename: "Old Book.epub", source: "scan",
                            enqueue_followups: false, mode: :reference, scan_roots: [ root ])

      entry = ImportFile.find_by(path: old_path.to_s)
      expect(entry.status).to eq("removed")
      expect(entry.message).to eq("relocated to #{new_path}")
      expect(entry.book_file_id).to be_nil
    end

    it "repoints a row whose file still exists but has drifted outside the scan roots (hardlink still present)" do
      old_path = outside.join("Old Book.epub")
      write(old_path, "same content")
      sha = Digest::SHA256.file(old_path).hexdigest
      book = create(:book)
      stale = create(:book_file, book: book, path: old_path.to_s, sha256: sha, size: File.size(old_path),
                     source: "scan")

      new_path = root.join("fiction", "sf", "Author", "Old Book.epub")
      write(new_path, "same content")

      result = described_class.call(new_path, original_filename: "Old Book.epub", source: "scan",
                                     enqueue_followups: false, mode: :reference, scan_roots: [ root ])

      expect(result.relocated?).to be(true)
      expect(stale.reload.path).to eq(new_path.to_s)
      expect(File).to exist(old_path) # external files are never deleted
    end

    it "records a plain duplicate when the existing row's file exists and is already under a scan root" do
      existing_path = root.join("fiction", "sf", "Author", "Existing.epub")
      write(existing_path, "same content")
      sha = Digest::SHA256.file(existing_path).hexdigest
      book = create(:book)
      existing = create(:book_file, book: book, path: existing_path.to_s, sha256: sha,
                        size: File.size(existing_path), source: "scan")

      new_path = root.join("fiction", "sf", "Author", "Existing (copy).epub")
      write(new_path, "same content")

      result = described_class.call(new_path, original_filename: "Existing (copy).epub", source: "scan",
                                     enqueue_followups: false, mode: :reference, scan_roots: [ root ])

      expect(result.relocated?).to be(false)
      expect(result.duplicate?).to be(true)
      expect(result.book_file).to eq(existing)
      expect(existing.reload.path).to eq(existing_path.to_s) # untouched
      expect(BookFile.find_by(path: new_path.to_s)).to be_nil
    end

    it "prefers repointing a row whose file is missing over one whose file still exists elsewhere" do
      content = "duplicated bytes across two stale rows"
      present_old_path = outside.join("Present.epub")
      missing_old_path = outside.join("Missing.azw3")
      write(present_old_path, content)
      write(missing_old_path, content)
      sha = Digest::SHA256.file(present_old_path).hexdigest

      book = create(:book)
      present_row = create(:book_file, book: book, format: "epub", path: present_old_path.to_s, sha256: sha,
                           size: File.size(present_old_path), source: "scan")
      missing_row = create(:book_file, book: book, format: "azw3", path: missing_old_path.to_s, sha256: sha,
                           size: File.size(missing_old_path), source: "scan")
      FileUtils.rm_f(missing_old_path)

      new_path = root.join("fiction", "sf", "Author", "New.epub")
      write(new_path, content)

      result = described_class.call(new_path, original_filename: "New.epub", source: "scan",
                                     enqueue_followups: false, mode: :reference, scan_roots: [ root ])

      expect(result.relocated?).to be(true)
      expect(result.book_file).to eq(missing_row)
      expect(missing_row.reload.path).to eq(new_path.to_s)
      expect(present_row.reload.path).to eq(present_old_path.to_s) # untouched
    end

    it "never repoints onto a path already owned by another BookFile" do
      missing_old_path = outside.join("Missing.epub")
      write(missing_old_path, "same content")
      sha = Digest::SHA256.file(missing_old_path).hexdigest
      book = create(:book)
      stale = create(:book_file, book: book, path: missing_old_path.to_s, sha256: sha,
                     size: File.size(missing_old_path), source: "scan")
      FileUtils.rm_f(missing_old_path)

      new_path = root.join("fiction", "sf", "Author", "Taken.epub")
      write(new_path, "same content")
      other_book = create(:book)
      create(:book_file, book: other_book, path: new_path.to_s, sha256: sha, size: File.size(new_path),
             source: "scan")

      result = described_class.call(new_path, original_filename: "Taken.epub", source: "scan",
                                     enqueue_followups: false, mode: :reference, scan_roots: [ root ])

      expect(result.relocated?).to be(false)
      expect(stale.reload.path).to eq(missing_old_path.to_s) # untouched
    end

    it "does not relocate when scan_roots is not given (uploads/conversions keep today's plain-duplicate behavior)" do
      old_path = outside.join("Old Book.epub")
      write(old_path, "same content")
      sha = Digest::SHA256.file(old_path).hexdigest
      book = create(:book)
      stale = create(:book_file, book: book, path: old_path.to_s, sha256: sha, size: File.size(old_path),
                     source: "scan")
      FileUtils.rm_f(old_path)

      new_path = root.join("fiction", "sf", "Author", "Old Book.epub")
      write(new_path, "same content")

      result = described_class.call(new_path, original_filename: "Old Book.epub", mode: :reference)

      expect(result.relocated?).to be(false)
      expect(result.duplicate?).to be(true)
      expect(stale.reload.path).to eq(old_path.to_s)
    end
  end
end
