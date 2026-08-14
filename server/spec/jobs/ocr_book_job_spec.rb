require 'rails_helper'

RSpec.describe OcrBookJob do
  let(:book) { create(:book) }
  let(:source) { create(:book_file, :on_disk, book: book, format: "pdf", sha256: "src-sha") }
  let(:conversion) { create(:conversion, :ocr, book: book, book_file: source) }

  def stub_ocr(text: "")
    allow(Library::Ocr).to receive(:call) do |_source_path, output_path, **_opts|
      File.write(output_path, "ocr'd pdf bytes")
      text
    end
  end

  it "runs on its own single-threaded ocr queue" do
    expect(described_class.new.queue_name).to eq("ocr")
  end

  it "OCRs the source pdf, records the companion on the book_file, and reindexes" do
    stub_ocr

    expect {
      described_class.perform_now(conversion.id)
    }.to have_enqueued_job(IndexBookJob).with(book.id).on_queue("indexing")

    expect(conversion.reload).to be_completed
    source.reload
    expect(source.ocr_path).to eq("ocr/#{book.public_id}.ocr.pdf")
    expect(source.ocr_source_sha256).to eq("src-sha")
    expect(source.ocr_sha256).to eq(Library.sha256(source.ocr_absolute_path))
    expect(source.ocr_size).to eq(File.size(source.ocr_absolute_path))
    expect(source).to be_ocr_fresh
  end

  it "always reindexes, even when the book already had fulltext" do
    BookSearch.index_book!(book, fulltext: "some pre-existing text")
    stub_ocr

    expect {
      described_class.perform_now(conversion.id)
    }.to have_enqueued_job(IndexBookJob).with(book.id)
  end

  it "maps the book's language and passes it through to Library::Ocr.call" do
    book.update!(language: "deu")
    stub_ocr

    described_class.perform_now(conversion.id)

    expect(Library::Ocr).to have_received(:call).with(source.absolute_path, anything, language: "deu+eng")
  end

  it "leaves the original source file untouched" do
    original = File.binread(source.absolute_path)
    stub_ocr

    described_class.perform_now(conversion.id)

    expect(File.binread(source.absolute_path)).to eq(original)
  end

  it "marks the conversion failed without re-raising when Library::Ocr reports an expected error" do
    allow(Library::Ocr).to receive(:call).and_raise(Library::Ocr::Error, "boom")

    expect { described_class.perform_now(conversion.id) }.not_to raise_error

    expect(conversion.reload).to be_failed
    expect(conversion.error).to eq("boom")
  end

  it "marks the conversion failed and re-raises an unexpected error so the job can be retried" do
    allow(Library::Ocr).to receive(:call).and_raise(StandardError, "disk exploded")

    expect { described_class.perform_now(conversion.id) }.to raise_error(StandardError, "disk exploded")

    expect(conversion.reload).to be_failed
    expect(conversion.error).to eq("disk exploded")
  end

  it "does nothing when the conversion is no longer pending" do
    conversion.update!(status: "completed")
    expect(Library::Ocr).not_to receive(:call)

    expect { described_class.perform_now(conversion.id) }.not_to raise_error
  end

  it "does nothing when the conversion no longer exists" do
    expect { described_class.perform_now(-1) }.not_to raise_error
  end
end
