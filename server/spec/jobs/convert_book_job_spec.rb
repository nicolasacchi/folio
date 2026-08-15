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
      allow(Calibre).to receive(:convert)
      allow(Library::Ingest).to receive(:call)
        .and_return(Library::Ingest::Result.new(book, pdf_source, false, false))

      described_class.perform_now(ocr_conversion.id)

      expect(Calibre).to have_received(:convert).with(pdf_source.ocr_absolute_path, anything, options: anything)
    end
  end

  describe "fulltext reindex follow-up" do
    before do
      allow(Calibre).to receive(:convert)
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
