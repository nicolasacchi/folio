require 'rails_helper'

# Exercises the sqlite-vec store with fake vectors; the ONNX model itself
# is stubbed so tests stay fast and network-free.
RSpec.describe Library::Embeddings do
  before do
    described_class.reset!
    FileUtils.rm_f(described_class.db_path)
    allow(described_class).to receive(:embed) do |texts|
      texts.map { |text| fake_vector(text) }
    end
  end

  after do
    described_class.reset!
    FileUtils.rm_f(described_class.db_path)
  end

  # Deterministic unit vector seeded by the text's hash.
  def fake_vector(text)
    random = Random.new(Zlib.crc32(text))
    raw = Array.new(described_class::DIMENSIONS) { random.rand - 0.5 }
    norm = Math.sqrt(raw.sum { |value| value * value })
    raw.map { |value| value / norm }
  end

  it "stores vectors and finds a book most similar to itself-like text" do
    dune = create(:book, title: "Dune", author: "Frank Herbert", description: "Desert planet epic")
    other = create(:book, title: "Cooking Pasta", author: "Chef", description: "Recipes")
    described_class.index_books!([ dune, other ])

    expect(described_class.count).to eq(2)

    hits = described_class.nearest(text: described_class.text_for(dune), limit: 1)
    expect(hits.first.first).to eq(dune.id)
  end

  it "excludes the book itself from similar-book lookups" do
    books = [ "Alpha", "Beta", "Gamma" ].map { |title| create(:book, title: title) }
    described_class.index_books!(books)

    hits = described_class.nearest(book: books.first, limit: 2)
    expect(hits.map(&:first)).not_to include(books.first.id)
    expect(hits.size).to eq(2)
  end

  it "re-embedding a book replaces its vector instead of duplicating it" do
    book = create(:book, title: "Original")
    described_class.index_book!(book)
    book.update!(title: "Renamed")
    described_class.index_book!(book)

    expect(described_class.count).to eq(1)
  end

  it "removes vectors when asked" do
    book = create(:book)
    described_class.index_book!(book)
    described_class.remove_book!(book.id)

    expect(described_class.count).to eq(0)
  end

  describe ".text_for" do
    it "prepends the category when the book has one" do
      book = create(:book, title: "Dune", author: "Frank Herbert", category: "fiction/sf")

      expect(described_class.text_for(book)).to eq("[fiction/sf] Dune. Frank Herbert")
    end

    it "does not prepend anything when the book has no category" do
      book = create(:book, title: "Dune", author: "Frank Herbert", category: nil)

      expect(described_class.text_for(book)).to eq("Dune. Frank Herbert")
    end
  end

  describe ".chunk_text" do
    it "returns a single chunk for text shorter than the target window" do
      text = "A short passage that fits in one chunk easily."

      expect(described_class.chunk_text(text)).to eq([ text ])
    end

    it "returns an empty array for blank input" do
      expect(described_class.chunk_text("")).to eq([])
      expect(described_class.chunk_text("   \n\t  ")).to eq([])
      expect(described_class.chunk_text(nil)).to eq([])
    end

    it "splits long text into multiple windows without ever cutting a word in half" do
      text = (1..3000).map { |i| "w#{i}" }.join(" ")

      chunks = described_class.chunk_text(text)

      expect(chunks.size).to be > 1
      chunks.each do |chunk|
        expect(chunk.split(/\s+/)).to all(match(/\Aw\d+\z/))
      end
    end

    it "sizes windows close to the target, not wildly shorter or longer" do
      text = (1..3000).map { |i| "w#{i}" }.join(" ")

      chunks = described_class.chunk_text(text)

      # Every window but the last (which just holds whatever's left) is
      # within the boundary-search slack of the target size.
      chunks[0..-2].each do |chunk|
        expect(chunk.length).to be_within(described_class::CHUNK_BOUNDARY_LOOKBACK).of(described_class::CHUNK_TARGET_CHARS)
      end
    end

    it "overlaps consecutive windows so a boundary word isn't lost entirely" do
      text = (1..3000).map { |i| "w#{i}" }.join(" ")

      chunks = described_class.chunk_text(text)

      expect(chunks[0].split(/\s+/) & chunks[1].split(/\s+/)).not_to be_empty
    end

    it "prefers a paragraph break as a split point when one is available near the target boundary" do
      paragraph_one = ("alpha " * 190).strip
      text = "#{paragraph_one}\n\n#{("beta " * 100).strip}"

      chunks = described_class.chunk_text(text)

      expect(chunks.first).to eq(paragraph_one)
    end

    it "caps the number of windows for a huge book, sampling across the whole text rather than truncating" do
      text = (1..200_000).map { |i| "w#{i}" }.join(" ")

      chunks = described_class.chunk_text(text)

      expect(chunks.size).to eq(described_class::MAX_CHUNKS_PER_BOOK)
      # A naive truncation to the first MAX_CHUNKS_PER_BOOK windows would
      # never reach anywhere near the end of a 200k-word text.
      expect(chunks.last).to match(/w19\d{4}/)
    end
  end

  describe "chunk vectors" do
    let(:book) { create(:book, title: "Dune", author: "Frank Herbert") }

    describe ".index_book_chunks!" do
      it "chunks, embeds and stores rows keyed by book_id" do
        text = ("alpha beta gamma delta epsilon " * 100).strip
        expected_chunks = described_class.chunk_text(text)
        expect(expected_chunks.size).to be >= 2

        stored = described_class.index_book_chunks!(book, fulltext: text)

        expect(stored).to eq(expected_chunks.size)
        expect(described_class.chunk_count).to eq(expected_chunks.size)
        expect(described_class.chunk_book_count).to eq(1)
      end

      it "returns 0 and stores nothing for blank fulltext" do
        expect(described_class.index_book_chunks!(book, fulltext: "   ")).to eq(0)
        expect(described_class.chunk_count).to eq(0)
      end

      it "returns 0 without touching the store when embeddings are unavailable" do
        allow(described_class).to receive(:available?).and_return(false)

        result = described_class.index_book_chunks!(book, fulltext: "alpha beta gamma delta epsilon " * 100)

        expect(result).to eq(0)
        expect(described_class.chunk_count).to eq(0)
      end

      it "re-indexing replaces rather than duplicates a book's chunks" do
        text = ("alpha beta gamma delta epsilon " * 100).strip
        described_class.index_book_chunks!(book, fulltext: text)
        count_before = described_class.chunk_count

        described_class.index_book_chunks!(book, fulltext: text)

        expect(described_class.chunk_count).to eq(count_before)
      end

      it "clears existing chunks when re-indexed with blank fulltext" do
        described_class.index_book_chunks!(book, fulltext: "alpha beta gamma delta epsilon " * 100)
        expect(described_class.chunk_count).to be > 0

        described_class.index_book_chunks!(book, fulltext: "")

        expect(described_class.chunk_count).to eq(0)
      end

      it "defaults to BookSearch's stored fulltext when none is passed" do
        BookSearch.index_book!(book, fulltext: "alpha beta gamma delta epsilon " * 100)

        described_class.index_book_chunks!(book)

        expect(described_class.chunk_count).to be > 0
      end
    end

    describe ".nearest_chunks" do
      it "finds the book whose chunk matches the query text" do
        other = create(:book, title: "Cooking Pasta")
        described_class.index_book_chunks!(book, fulltext: "a passage about desert planets and sandworms")
        described_class.index_book_chunks!(other, fulltext: "a recipe for spaghetti carbonara")

        hits = described_class.nearest_chunks(text: "a passage about desert planets and sandworms", limit: 5)

        expect(hits.first.first).to eq(book.id)
      end

      it "ranks a book by its single best-matching chunk, not an average of its chunks" do
        filler = ("lorem ipsum dolor sit amet " * 60).strip
        needle = "a very specific passage about desert planets and giant sandworms"
        fulltext = "#{filler}\n\n#{needle}"
        chunks = described_class.chunk_text(fulltext)
        expect(chunks.size).to be >= 2
        target_chunk = chunks.find { |c| c.include?("sandworms") }

        described_class.index_book_chunks!(book, fulltext: fulltext)

        hits = described_class.nearest_chunks(text: target_chunk, limit: 5)
        hit = hits.find { |id, _distance, _snippet| id == book.id }

        expect(hit).not_to be_nil
        # An exact-text-match chunk embeds identically to the query, so its
        # cosine distance is ~0 — provably the chunk picked, not e.g. the
        # filler chunk's much larger distance or an average of the two.
        expect(hit[1]).to be_within(1e-4).of(0.0)
      end

      it "returns a snippet alongside each hit" do
        described_class.index_book_chunks!(book, fulltext: "a passage about desert planets and sandworms")

        hits = described_class.nearest_chunks(text: "a passage about desert planets and sandworms", limit: 5)

        expect(hits.first[2]).to include("sandworms")
      end

      it "returns an empty array when embeddings are unavailable" do
        allow(described_class).to receive(:available?).and_return(false)

        expect(described_class.nearest_chunks(text: "anything", limit: 5)).to eq([])
      end

      it "returns an empty array when no chunks are indexed" do
        expect(described_class.nearest_chunks(text: "anything", limit: 5)).to eq([])
      end
    end

    describe ".remove_book_chunks!" do
      it "removes only the given book's chunks" do
        other = create(:book)
        described_class.index_book_chunks!(book, fulltext: "alpha beta gamma delta epsilon " * 100)
        described_class.index_book_chunks!(other, fulltext: "zeta eta theta iota kappa " * 100)

        described_class.remove_book_chunks!(book.id)

        expect(described_class.chunk_book_count).to eq(1)
      end

      it "does not raise for a book with no chunks" do
        expect { described_class.remove_book_chunks!(book.id) }.not_to raise_error
      end
    end

    describe ".remove_book!" do
      it "also removes the book's chunk vectors" do
        described_class.index_book!(book)
        described_class.index_book_chunks!(book, fulltext: "alpha beta gamma delta epsilon " * 100)

        described_class.remove_book!(book.id)

        expect(described_class.count).to eq(0)
        expect(described_class.chunk_count).to eq(0)
      end
    end
  end

  describe "fork safety" do
    before { skip "sqlite-vec/informers unavailable in this environment" unless described_class.available? }

    # Regression coverage for the incident where Solid Queue workers — forked
    # from a supervisor that was itself forked from the Puma master — ended
    # up sharing a single "not closed" SQLite handle and died mid-job with
    # "prepare called on a closed database". Clearing SQLite3::ForkSafety's
    # own registry right before forking reproduces exactly what the
    # supervisor generation leaves behind: by the time the worker forks, the
    # registry is already empty, so the worker's own fork-safety hook finds
    # nothing to discard and would otherwise hand it a shared handle that
    # still reports closed? == false. See ForkSafeSqlite.
    it "opens its own handle in a forked child even when the fork-safety registry was already cleared" do
      book = create(:book, title: "Forked Book")
      described_class.index_book!(book)

      SQLite3::ForkSafety.instance_variable_get(:@databases).clear

      result = ForkProbe.run do
        # The handle inherited from the parent via fork's copy-on-write
        # memory — reusing this (as the old closed?-only guard could) is
        # exactly the bug.
        inherited_db = described_class.instance_variable_get(:@db)
        described_class.index_book!(book)
        child_db = described_class.instance_variable_get(:@db)
        {
          pid: Process.pid,
          db_pid: described_class.instance_variable_get(:@db_pid),
          reused_inherited_handle: child_db.equal?(inherited_db),
          closed: child_db.closed?
        }
      end

      expect(result[:ok]).to be(true), result[:error]
      value = result[:value]
      expect(value[:pid]).not_to eq(Process.pid)
      expect(value[:db_pid]).to eq(value[:pid])
      expect(value[:reused_inherited_handle]).to be false
      expect(value[:closed]).to be false
    end

    it "reopens rather than reusing the handle when the memoized pid no longer matches the current process" do
      described_class.with_db { |db| db.execute("SELECT 1") }
      original_db = described_class.instance_variable_get(:@db)
      described_class.instance_variable_set(:@db_pid, Process.pid + 1)

      described_class.with_db { |db| db.execute("SELECT 1") }

      expect(described_class.instance_variable_get(:@db)).not_to equal(original_db)
      expect(described_class.instance_variable_get(:@db_pid)).to eq(Process.pid)
      expect(original_db.closed?).to be false
    end
  end
end
