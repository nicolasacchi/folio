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
