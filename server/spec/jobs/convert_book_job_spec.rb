require 'rails_helper'

RSpec.describe ConvertBookJob do
  let(:book) { create(:book) }
  let(:source) { create(:book_file, book: book, format: "epub") }
  let(:conversion) { create(:conversion, book: book, book_file: source, target_format: "azw3") }

  it "marks the conversion failed without re-raising when Calibre reports an expected conversion error" do
    allow(Calibre).to receive(:convert).and_raise(Calibre::Error, "boom")

    expect { described_class.perform_now(conversion.id) }.not_to raise_error

    expect(conversion.reload).to be_failed
    expect(conversion.error).to eq("boom")
  end

  it "marks the conversion failed and re-raises an unexpected error so the job can be retried" do
    allow(Calibre).to receive(:convert).and_raise(StandardError, "disk exploded")

    expect { described_class.perform_now(conversion.id) }.to raise_error(StandardError, "disk exploded")

    expect(conversion.reload).to be_failed
    expect(conversion.error).to eq("disk exploded")
  end

  # Production incident: book 39589's Convert-to-TXT (Conversion #7941) ran
  # ebook-convert on an OCR'd scan, which exited 0 but produced a 0-byte txt.
  # Library::Ingest then created a real (empty) book_file that outranked the
  # real pdf in Book::READABLE_FORMATS/KINDLE_FORMATS. See
  # ConvertBookJob::MIN_OUTPUT_SIZE.
  describe "when ebook-convert exits 0 but writes a near-empty file" do
    before do
      allow(Calibre).to receive(:convert) do |_source, target, **_options|
        File.write(target, "x" * 10)
        target
      end
      allow(Library::Ingest).to receive(:call)
    end

    it "fails the conversion instead of ingesting the junk output" do
      described_class.perform_now(conversion.id)

      expect(conversion.reload).to be_failed
      expect(conversion.error).to include("10 bytes")
      expect(Library::Ingest).not_to have_received(:call)
    end

    it "does not create a book_file" do
      conversion_id = conversion.id # force conversion (and its source book_file) to exist before sampling the count

      expect { described_class.perform_now(conversion_id) }.not_to change(book.book_files, :count)
    end
  end

  describe "when ebook-convert exits 0 but writes nothing at all" do
    it "fails the conversion instead of ingesting a missing file" do
      allow(Calibre).to receive(:convert) # no-op: never writes the target
      allow(Library::Ingest).to receive(:call)

      described_class.perform_now(conversion.id)

      expect(conversion.reload).to be_failed
      expect(conversion.error).to include("0 bytes")
      expect(Library::Ingest).not_to have_received(:call)
    end
  end

  describe "converting a pdf source with a fresh OCR companion" do
    let(:pdf_source) { create(:book_file, :on_disk, book: book, format: "pdf", sha256: "src-sha") }
    let(:ocr_conversion) { create(:conversion, book: book, book_file: pdf_source, target_format: "epub") }

    before do
      ocr_path = "ocr/#{book.public_id}.ocr.pdf"
      FileUtils.mkdir_p(Library.base_root.join(ocr_path).dirname)
      File.write(Library.base_root.join(ocr_path), "ocr'd pdf bytes")
      pdf_source.update!(ocr_path: ocr_path, ocr_source_sha256: pdf_source.sha256)
    end

    it "converts from the OCR companion, not the raw scan, so the text layer carries over" do
      allow(Calibre).to receive(:convert) do |_source, target, **_options|
        File.write(target, "converted epub bytes " * 10)
        target
      end
      allow(Library::Ingest).to receive(:call)
        .and_return(Library::Ingest::Result.new(book, pdf_source, false, false))

      described_class.perform_now(ocr_conversion.id)

      expect(Calibre).to have_received(:convert).with(pdf_source.ocr_absolute_path, anything, options: anything)
    end
  end

  describe "fulltext reindex follow-up" do
    before do
      allow(Calibre).to receive(:convert) do |_source, target, **_options|
        File.write(target, "converted book bytes " * 10)
        target
      end
      allow(Library::Ingest).to receive(:call)
        .and_return(Library::Ingest::Result.new(book, source, false, false))
    end

    it "queues IndexBookJob on its own queue for an opted-in book still missing fulltext" do
      book.update!(fulltext_enabled: true)

      expect { described_class.perform_now(conversion.id) }
        .to have_enqueued_job(IndexBookJob).with(book.id).on_queue("indexing")
    end

    it "does not queue IndexBookJob for an opted-in book that already has fulltext" do
      book.update!(fulltext_enabled: true)
      BookSearch.index_book!(book, fulltext: "already extracted")

      expect { described_class.perform_now(conversion.id) }.not_to have_enqueued_job(IndexBookJob)
    end

    # The catalog defaults fulltext_enabled: false — without this gate,
    # every conversion of every opted-out book would fire a pointless FTS
    # write (and, before this fix, onto the :conversion queue, blocking
    # reader auto-conversions and Kindle prep behind a minutes-long extraction).
    it "does not queue IndexBookJob for a book that is not opted in to full-text search" do
      expect { described_class.perform_now(conversion.id) }.not_to have_enqueued_job(IndexBookJob)
    end
  end
end
