require "rails_helper"

RSpec.describe TextCompanionJob do
  let(:book) { create(:book, title: "A Book", author: "An Author") }
  let(:source) { create(:book_file, :on_disk, book: book, format: "pdf", sha256: "src-sha") }
  let(:conversion) { create(:conversion, :text, book: book, book_file: source) }

  def stub_extract_text(text: "x" * 300)
    allow(Calibre).to receive(:extract_text).and_return(text)
  end

  def stub_convert_success
    allow(Calibre).to receive(:convert) do |_source_path, target, **_opts|
      File.write(target, "azw3 bytes")
      target
    end
  end

  it "runs on the shared :conversion queue" do
    expect(described_class.new.queue_name).to eq("conversion")
  end

  it "does nothing when the conversion is no longer pending" do
    conversion.update!(status: "completed")
    expect(Calibre).not_to receive(:extract_text)

    expect { described_class.perform_now(conversion.id) }.not_to raise_error
  end

  it "does nothing when the conversion no longer exists" do
    expect { described_class.perform_now(-1) }.not_to raise_error
  end

  describe "success" do
    before do
      stub_extract_text
      stub_convert_success
    end

    it "writes the text companion, builds the Kindle AZW3, completes the conversion, and reindexes" do
      expect {
        described_class.perform_now(conversion.id)
      }.to have_enqueued_job(IndexBookJob).with(book.id)

      expect(conversion.reload).to be_completed
      source.reload

      expect(source.text_path).to eq("text/#{book.public_id}.txt")
      expect(File.read(source.text_absolute_path)).to eq("x" * 300)
      expect(source.text_sha256).to eq(Library.sha256(source.text_absolute_path))
      expect(source.text_size).to eq(File.size(source.text_absolute_path))
      expect(source.text_source_sha256).to eq("src-sha")
      expect(source).to be_text_fresh

      expect(source.text_kindle_path).to eq("text/#{book.public_id}.azw3")
      expect(File.read(source.text_kindle_absolute_path)).to eq("azw3 bytes")
      expect(source.text_kindle_sha256).to eq(Library.sha256(source.text_kindle_absolute_path))
      expect(source.text_kindle_size).to eq(File.size(source.text_kindle_absolute_path))
      expect(source).to be_text_kindle_usable
    end

    it "extracts from the OCR companion (not the raw scan) when one is fresh" do
      ocr_path = "ocr/#{book.public_id}.ocr.pdf"
      FileUtils.mkdir_p(Library.base_root.join(ocr_path).dirname)
      File.write(Library.base_root.join(ocr_path), "ocr'd pdf bytes")
      source.update!(ocr_path: ocr_path, ocr_sha256: "ocr-sha", ocr_source_sha256: source.sha256)

      described_class.perform_now(conversion.id)

      expect(Calibre).to have_received(:extract_text).with(source.ocr_absolute_path)
      expect(source.reload.text_source_sha256).to eq("ocr-sha")
    end

    it "passes title/authors metadata to the AZW3 build (the .txt source has none of its own)" do
      described_class.perform_now(conversion.id)

      expect(Calibre).to have_received(:convert).with(
        source.reload.text_absolute_path, anything, options: [ "--title", "A Book", "--authors", "An Author" ]
      )
    end

    it "passes --cover when the book has one" do
      FileUtils.mkdir_p(Library.cover_path(book).dirname)
      File.write(Library.cover_path(book), "cover bytes")

      described_class.perform_now(conversion.id)

      expect(Calibre).to have_received(:convert).with(
        anything, anything, options: array_including("--cover", Library.cover_path(book).to_s)
      )
    end

    it "leaves the original source file untouched" do
      original = File.binread(source.absolute_path)

      described_class.perform_now(conversion.id)

      expect(File.binread(source.absolute_path)).to eq(original)
    end

    it "neutralizes the store identity Calibre stamps on its own azw3 output (see Library::KindlePrep)" do
      allow(Calibre).to receive(:convert) do |_source_path, target, **_opts|
        MobiFixture.write(target, exth: { 113 => "0a37-uuid", 112 => "calibre:0a37", 501 => "EBOK" })
        target
      end

      described_class.perform_now(conversion.id)
      source.reload

      # Same assertion shape as kindle_prep_spec: no ASIN left, and the
      # cdeType says personal document rather than the calibre-stamped
      # store identity.
      identity = Library::MobiCde.parse(source.text_kindle_absolute_path)
      expect(identity).to eq(asin: nil, cde_type: "PDOC")
      # And stamped from the patched (post-rename) bytes, not from
      # whatever Calibre.convert originally wrote to staging.
      expect(source.text_kindle_sha256).to eq(Library.sha256(source.text_kindle_absolute_path))
    end

    it "invokes KindlePrep's neutralization on the staging file before it's renamed to the final path" do
      staging_path = Library::TextCompanion.root.join("staging-#{book.public_id}.azw3")
      final_path = Library::TextCompanion.kindle_path(book)

      expect(Library::KindlePrep).to receive(:neutralize_store_identity!) do |path|
        expect(path.to_s).to eq(staging_path.to_s)
        expect(File.exist?(final_path)).to be(false)
      end

      described_class.perform_now(conversion.id)
    end
  end

  describe "blank/absurdly short extraction" do
    it "fails the conversion and stores no companion when extraction returns blank" do
      stub_extract_text(text: "")

      expect { described_class.perform_now(conversion.id) }.not_to raise_error

      expect(conversion.reload).to be_failed
      expect(conversion.error).to include("too short")
      expect(source.reload.text_path).to be_nil
    end

    it "fails the conversion when extraction returns only a few characters" do
      stub_extract_text(text: "cover page only")

      described_class.perform_now(conversion.id)

      expect(conversion.reload).to be_failed
      expect(source.reload.text_path).to be_nil
    end

    it "never attempts the AZW3 build when extraction already failed" do
      stub_extract_text(text: "")
      expect(Calibre).not_to receive(:convert)

      described_class.perform_now(conversion.id)
    end

    it "does not queue IndexBookJob" do
      stub_extract_text(text: "")

      expect { described_class.perform_now(conversion.id) }.not_to have_enqueued_job(IndexBookJob)
    end
  end

  describe "AZW3 build failure keeps the plain-text companion" do
    before do
      stub_extract_text
      allow(Calibre).to receive(:convert).and_raise(Calibre::Error, "ebook-convert boom")
    end

    it "fails the conversion with the Calibre error but keeps the text companion usable" do
      expect { described_class.perform_now(conversion.id) }.not_to raise_error

      expect(conversion.reload).to be_failed
      expect(conversion.error).to eq("ebook-convert boom")

      source.reload
      expect(source).to be_text_fresh
      expect(source.text_kindle_path).to be_nil
      expect(source).not_to be_text_kindle_usable
    end

    it "clears a previously-built (now stale) text_kindle_* rather than leaving it stale" do
      source.update!(
        text_kindle_path: "text/#{book.public_id}.azw3",
        text_kindle_sha256: "stale-sha",
        text_kindle_size: 99
      )

      described_class.perform_now(conversion.id)

      source.reload
      expect(source.text_kindle_path).to be_nil
      expect(source.text_kindle_sha256).to be_nil
      expect(source.text_kindle_size).to be_nil
    end

    it "does not queue IndexBookJob (the conversion never completes)" do
      expect { described_class.perform_now(conversion.id) }.not_to have_enqueued_job(IndexBookJob)
    end
  end

  it "marks the conversion failed and re-raises an unexpected error so the job can be retried" do
    allow(Calibre).to receive(:extract_text).and_raise(StandardError, "disk exploded")

    expect { described_class.perform_now(conversion.id) }.to raise_error(StandardError, "disk exploded")

    expect(conversion.reload).to be_failed
    expect(conversion.error).to eq("disk exploded")
  end
end
