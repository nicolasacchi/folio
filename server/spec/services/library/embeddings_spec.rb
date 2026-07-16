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
end
