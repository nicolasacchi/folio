require 'rails_helper'

RSpec.describe IndexBookJob do
  # Fulltext extraction shells out to Calibre and can take seconds per book;
  # it must stay off the shared default worker (see config/queue.yml) so a
  # catalog-wide index run never blocks device-API-adjacent jobs.
  it "runs on its own indexing queue, not the shared default worker" do
    expect(described_class.queue_name).to eq("indexing")
  end

  it "indexes the book and sets has_fulltext when the book is opted in and Calibre extracts text" do
    book = create(:book, fulltext_enabled: true)
    create(:book_file, :on_disk, book: book, format: "epub")
    allow(Calibre).to receive(:available?).and_return(true)
    allow(Calibre).to receive(:extract_text).and_return("extracted body text")

    described_class.perform_now(book.id)

    expect(book.reload.has_fulltext).to be(true)
    expect(BookSearch.search("extracted").map { |hit| hit[:book_id] }).to eq([ book.id ])
  end

  it "leaves has_fulltext false and never calls Calibre when the book is not opted in" do
    book = create(:book, fulltext_enabled: false)
    create(:book_file, :on_disk, book: book, format: "epub")
    allow(Calibre).to receive(:available?).and_return(true)
    allow(Calibre).to receive(:extract_text)

    described_class.perform_now(book.id)

    expect(Calibre).not_to have_received(:extract_text)
    expect(book.reload.has_fulltext).to be(false)
  end

  it "extracts from the OCR companion instead of the raw pdf when it is fresh" do
    book = create(:book, fulltext_enabled: true)
    pdf = create(:book_file, :on_disk, book: book, format: "pdf", sha256: "src-sha")
    companion = Library.base_root.join("ocr", "#{book.public_id}.ocr.pdf")
    FileUtils.mkdir_p(companion.dirname)
    File.write(companion, "companion bytes")
    pdf.update!(ocr_path: "ocr/#{book.public_id}.ocr.pdf", ocr_source_sha256: "src-sha")
    allow(Calibre).to receive(:available?).and_return(true)
    allow(Calibre).to receive(:extract_text).and_return("ocr'd text")

    described_class.perform_now(book.id)

    expect(Calibre).to have_received(:extract_text).with(companion)
    expect(book.reload.has_fulltext).to be(true)
  end

  it "leaves has_fulltext false when Calibre is unavailable" do
    book = create(:book, fulltext_enabled: true)
    create(:book_file, :on_disk, book: book, format: "epub")
    allow(Calibre).to receive(:available?).and_return(false)

    described_class.perform_now(book.id)

    expect(book.reload.has_fulltext).to be(false)
  end

  it "does nothing when the book no longer exists" do
    expect { described_class.perform_now(0) }.not_to raise_error
  end

  describe "chunk-level embedding follow-up" do
    before do
      allow(Calibre).to receive(:available?).and_return(true)
      allow(Calibre).to receive(:extract_text).and_return("extracted body text")
    end

    it "enqueues EmbedBookChunksJob on the indexing queue for an opted-in book" do
      book = create(:book, fulltext_enabled: true)
      create(:book_file, :on_disk, book: book, format: "epub")
      allow(Library::Embeddings).to receive(:available?).and_return(true)

      expect { described_class.perform_now(book.id) }
        .to have_enqueued_job(EmbedBookChunksJob).with(book.id).on_queue("indexing")
    end

    it "does not enqueue EmbedBookChunksJob when embeddings are unavailable" do
      book = create(:book, fulltext_enabled: true)
      create(:book_file, :on_disk, book: book, format: "epub")
      allow(Library::Embeddings).to receive(:available?).and_return(false)

      expect { described_class.perform_now(book.id) }.not_to have_enqueued_job(EmbedBookChunksJob)
    end

    # A book whose fulltext was just removed (unindex) still needs one embed
    # run so index_book_chunks! sees the now-empty fulltext and clears its
    # stale chunk vectors — even though this run itself extracts nothing.
    it "enqueues EmbedBookChunksJob when a previously-indexed book was just opted out" do
      book = create(:book, fulltext_enabled: false)
      BookSearch.index_book!(book, fulltext: "stale fulltext from before opting out")
      expect(book.reload.has_fulltext).to be(true)
      allow(Library::Embeddings).to receive(:available?).and_return(true)

      expect { described_class.perform_now(book.id) }
        .to have_enqueued_job(EmbedBookChunksJob).with(book.id).on_queue("indexing")

      expect(book.reload.has_fulltext).to be(false)
    end

    # A book that was never opted in must not churn the embeddings DB on
    # every metadata reindex — a catalog-wide metadata rebuild would
    # otherwise fire ~29k no-op embed jobs.
    it "does not enqueue EmbedBookChunksJob for a disabled book that never had fulltext" do
      book = create(:book, fulltext_enabled: false)
      allow(Library::Embeddings).to receive(:available?).and_return(true)

      expect { described_class.perform_now(book.id) }.not_to have_enqueued_job(EmbedBookChunksJob)
    end
  end
end
