require "rails_helper"

RSpec.describe IngestUploadJob do
  let(:source) { file_fixture("The Salt Road -- Ada Author.txt") }
  let(:stashed) { Rails.root.join("tmp", "ingest-upload-job-spec-#{SecureRandom.hex(4)}.txt") }

  before do
    # Calibre integration is covered by manual smoke tests; keep specs fast
    # and deterministic (same convention as spec/services/library/ingest_spec.rb).
    allow(Calibre).to receive(:metadata).and_return({})
    allow(Calibre).to receive(:extract_cover).and_return(false)
    FileUtils.cp(source, stashed)
  end

  after { FileUtils.rm_f(stashed) }

  it "ingests the stashed file using the original filename" do
    described_class.perform_now(stashed.to_s, original_filename: "The Salt Road -- Ada Author.txt")

    book = Book.find_by(title: "The Salt Road")
    expect(book).to be_present
    expect(book.author).to eq("Ada Author")
    expect(book.book_files.first.source).to eq("upload")
  end

  it "removes the stashed file afterwards" do
    described_class.perform_now(stashed.to_s, original_filename: "The Salt Road -- Ada Author.txt")

    expect(File.exist?(stashed)).to be(false)
  end

  it "logs and swallows an unsupported format, still removing the stash" do
    expect(Rails.logger).to receive(:warn).with(/unsupported format/)

    expect {
      described_class.perform_now(stashed.to_s, original_filename: "notes.xyz")
    }.not_to raise_error

    expect(File.exist?(stashed)).to be(false)
    expect(Book.count).to eq(0)
  end

  it "logs and swallows an unexpected error without re-raising for retry" do
    allow(Library::Ingest).to receive(:call).and_raise(StandardError, "wedged")

    expect(Rails.logger).to receive(:error).with(/wedged/)

    expect {
      described_class.perform_now(stashed.to_s, original_filename: "The Salt Road -- Ada Author.txt")
    }.not_to raise_error
    expect(File.exist?(stashed)).to be(false)
  end

  it "treats an already-ingested duplicate as a quiet success" do
    Library::Ingest.call(source, original_filename: source.basename.to_s)

    allow(Rails.logger).to receive(:info).and_call_original

    expect {
      described_class.perform_now(stashed.to_s, original_filename: "renamed.txt")
    }.not_to raise_error
    expect(Rails.logger).to have_received(:info).with(/already in the library/)
    expect(Book.count).to eq(1)
    expect(File.exist?(stashed)).to be(false)
  end
end
