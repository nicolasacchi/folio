require 'rails_helper'

RSpec.describe PrepareKindleFileJob do
  let(:book) { create(:book) }
  let(:file) { create(:book_file, book: book, format: "azw3", sha256: "src-sha") }

  before do
    MobiFixture.write(file.absolute_path, exth: { 501 => "EBOK" })
    allow(Calibre).to receive(:available?).and_return(false)
  end

  it "runs on the single-threaded conversion queue" do
    expect(described_class.new.queue_name).to eq("conversion")
  end

  # Manifest polls (~30s) can enqueue several of these for the same book
  # before the first finishes. The concurrency key is per-book so Solid
  # Queue serializes them (DB semaphore, at most 1 in flight) regardless
  # of how many worker processes/threads are configured for the queue.
  it "limits concurrency to one prep in flight per book" do
    expect(described_class.concurrency_limit).to eq(1)

    job = described_class.new(book.id)
    expect(job.concurrency_key).to eq("PrepareKindleFileJob/prepare-kindle-#{book.id}")

    other_job = described_class.new(book.id + 1)
    expect(other_job.concurrency_key).not_to eq(job.concurrency_key)
  end

  it "does the full prep when the delivery copy is stale" do
    file # materialize before setting the expectation
    expect(Library::KindlePrep).to receive(:prepare!).and_call_original

    described_class.perform_now(book.id)

    expect(file.reload).to be_prepared_fresh
  end

  # This is what makes duplicate enqueues (piled up before the first job
  # finishes) harmless once they do run: a rerun for an already-current
  # prepared copy is a no-op rather than repeating the Calibre work.
  it "no-ops a rerun once the prepared copy is already current for the source sha" do
    described_class.perform_now(book.id)
    file.reload
    expect(file).to be_prepared_fresh

    expect(Library::KindlePrep).not_to receive(:prepare!)

    described_class.perform_now(book.id)
  end

  it "re-prepares once the source sha changes" do
    described_class.perform_now(book.id)
    file.reload.update!(sha256: "new-sha")
    MobiFixture.write(file.absolute_path, exth: { 501 => "EBOK" })

    expect(Library::KindlePrep).to receive(:prepare!).and_call_original

    described_class.perform_now(book.id)

    expect(file.reload.prepared_source_sha256).to eq("new-sha")
  end

  it "tolerates a book that no longer exists" do
    expect { described_class.perform_now(-1) }.not_to raise_error
  end

  it "tolerates a book with no kindle-ready file" do
    epub_only = create(:book)
    create(:book_file, book: epub_only, format: "epub")

    expect(Library::KindlePrep).not_to receive(:prepare!)
    expect { described_class.perform_now(epub_only.id) }.not_to raise_error
  end
end
