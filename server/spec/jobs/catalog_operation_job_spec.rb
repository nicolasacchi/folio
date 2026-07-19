require 'rails_helper'

RSpec.describe CatalogOperationJob do
  it "queues Kindle conversions only for books without a deliverable file" do
    epub_only = create(:book)
    create(:book_file, book: epub_only, format: "epub")
    deliverable = create(:book)
    create(:book_file, book: deliverable, format: "azw3", path: "#{SecureRandom.hex(4)}/x.azw3")

    expect { described_class.perform_now("convert_all") }
      .to have_enqueued_job(EnsureKindleFormatJob).with(epub_only.id).exactly(:once)
  end

  it "merges every duplicate group into its best edition" do
    target = create(:book, title: "Dune", author: "F. H.")
    create(:book_file, :on_disk, book: target, format: "epub")
    create(:book_file, :on_disk, book: target, format: "azw3", path: "#{SecureRandom.hex(4)}/d.azw3")
    extra = create(:book, title: "Dune", author: "F. H.")
    create(:book_file, :on_disk, book: extra, format: "mobi", path: "#{SecureRandom.hex(4)}/d.mobi")

    described_class.perform_now("merge_duplicates")

    expect(Book.exists?(extra.id)).to be(false)
    expect(target.reload.formats).to contain_exactly("epub", "azw3", "mobi")
  end

  describe '"embed_chunks_all"' do
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

    it "does not raise, and does not index anything, when embeddings are unavailable" do
      allow(Library::Embeddings).to receive(:available?).and_return(false)
      book = create(:book)
      BookSearch.index_book!(book, fulltext: "alpha beta gamma delta epsilon " * 100)

      expect { described_class.perform_now("embed_chunks_all") }.not_to raise_error
      expect(Library::Embeddings.chunk_count).to eq(0)
    end

    it "builds chunk vectors for every book with stored fulltext, skipping books without any" do
      skip "sqlite-vec/informers unavailable in this environment" unless Library::Embeddings.available?

      with_fulltext = create(:book)
      BookSearch.index_book!(with_fulltext, fulltext: "alpha beta gamma delta epsilon " * 100)
      without_fulltext = create(:book)
      BookSearch.index_book!(without_fulltext, fulltext: nil)

      described_class.perform_now("embed_chunks_all")

      expect(Library::Embeddings.chunk_book_count).to eq(1)
      expect(Library::Embeddings.chunk_count).to be > 0
    end
  end
end
