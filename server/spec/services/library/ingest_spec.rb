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
end
