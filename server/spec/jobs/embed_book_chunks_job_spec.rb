require 'rails_helper'

RSpec.describe EmbedBookChunksJob do
  before do
    Library::Embeddings.reset!
    FileUtils.rm_f(Library::Embeddings.db_path)
    allow(Library::Embeddings).to receive(:embed) do |texts|
      texts.map { |text| Array.new(Library::Embeddings::DIMENSIONS) { text.hash % 1000 / 1000.0 } }
    end
  end

  after do
    Library::Embeddings.reset!
    FileUtils.rm_f(Library::Embeddings.db_path)
  end

  # Chunking + embedding up to MAX_CHUNKS_PER_BOOK windows is heavier than
  # a single metadata vector; it must stay off the shared default worker
  # (see config/queue.yml) so a catalog-wide backfill never blocks
  # device-API-adjacent jobs.
  it "runs on the indexing queue, not the shared default worker" do
    expect(described_class.queue_name).to eq("indexing")
  end

  it "does nothing when embeddings are unavailable" do
    allow(Library::Embeddings).to receive(:available?).and_return(false)
    book = create(:book)

    expect(Library::Embeddings).not_to receive(:index_book_chunks!)

    described_class.perform_now(book.id)
  end

  it "does nothing when the book no longer exists" do
    expect { described_class.perform_now(0) }.not_to raise_error
  end

  it "indexes the book's chunk vectors when embeddings are available" do
    skip "sqlite-vec/informers unavailable in this environment" unless Library::Embeddings.available?

    book = create(:book)
    BookSearch.index_book!(book, fulltext: "alpha beta gamma delta epsilon " * 100)

    described_class.perform_now(book.id)

    expect(Library::Embeddings.chunk_count).to be > 0
  end

  it "skips re-embed on a second perform for the same unchanged book" do
    skip "sqlite-vec/informers unavailable in this environment" unless Library::Embeddings.available?

    book = create(:book)
    BookSearch.index_book!(book, fulltext: "alpha beta gamma delta epsilon " * 100)

    described_class.perform_now(book.id)
    count_before = Library::Embeddings.chunk_count
    expect(count_before).to be > 0

    expect(Library::Embeddings).not_to receive(:embed)
    described_class.perform_now(book.id)

    expect(Library::Embeddings.chunk_count).to eq(count_before)
  end
end
