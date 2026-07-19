require "rails_helper"

RSpec.describe "Books hybrid (\"meaning\") search", type: :request do
  let!(:user) { create(:user) }

  before do
    post session_path, params: { email_address: user.email_address, password: "password" }
  end

  describe "mode=semantic, embeddings available" do
    before do
      Library::Embeddings.reset!
      FileUtils.rm_f(Library::Embeddings.db_path)
      allow(Library::Embeddings).to receive(:embed) do |texts|
        texts.map { |text| fake_vector(text) }
      end
    end

    after do
      Library::Embeddings.reset!
      FileUtils.rm_f(Library::Embeddings.db_path)
    end

    it "finds a book via a chunk-level match on text buried in the body, not just metadata" do
      skip "sqlite-vec/informers unavailable in this environment" unless Library::Embeddings.available?

      book = create(:book, title: "Untitled Notes")
      Library::Embeddings.index_book_chunks!(book, fulltext: "a passage about desert planets and sandworms")

      get root_path(q: "a passage about desert planets and sandworms", mode: "semantic")

      expect(response.body).to include("Untitled Notes")
      # The best-matching chunk's text is surfaced as a "why this result" line.
      expect(response.body).to include("sandworms")
    end

    it "falls back to the book-level vector when no chunk vectors are indexed yet" do
      skip "sqlite-vec/informers unavailable in this environment" unless Library::Embeddings.available?

      book = create(:book, title: "Dune", description: "Desert planet epic")
      Library::Embeddings.index_book!(book)

      get root_path(q: Library::Embeddings.text_for(book), mode: "semantic")

      expect(response.body).to include("Dune")
    end

    it "fuses FTS and vector results, ranking a book both agree on above one only FTS finds" do
      skip "sqlite-vec/informers unavailable in this environment" unless Library::Embeddings.available?

      agreed = create(:book, title: "Both Agree")
      BookSearch.index_book!(agreed, fulltext: "a shared query phrase right here")
      Library::Embeddings.index_book_chunks!(agreed, fulltext: "a shared query phrase right here")

      fts_only = create(:book, title: "FTS Alone")
      BookSearch.index_book!(fts_only, fulltext: "a shared query phrase but unrelated chunk content")
      Library::Embeddings.index_book_chunks!(fts_only, fulltext: "totally unrelated filler about gardening tools")

      get root_path(q: "a shared query phrase", mode: "semantic")

      body = response.body
      expect(body).to include("Both Agree").and include("FTS Alone")
      expect(body.index("Both Agree")).to be < body.index("FTS Alone")
    end

    it "does not N+1 loading books as the fused result count grows" do
      skip "sqlite-vec/informers unavailable in this environment" unless Library::Embeddings.available?

      make_matching_book = lambda do |i|
        book = create(:book, title: "Match #{i}")
        BookSearch.index_book!(book, fulltext: "matching shared content number #{i}")
        Library::Embeddings.index_book_chunks!(book, fulltext: "matching shared content number #{i}")
      end

      make_matching_book.call(0)
      queries_for_one = count_sql_queries { get root_path(q: "matching shared content", mode: "semantic") }
      expect(response).to have_http_status(:ok)

      4.times { |i| make_matching_book.call(i + 1) }
      queries_for_five = count_sql_queries { get root_path(q: "matching shared content", mode: "semantic") }
      expect(response).to have_http_status(:ok)

      expect(queries_for_five).to be <= queries_for_one + 2
    end

    def fake_vector(text)
      random = Random.new(Zlib.crc32(text))
      raw = Array.new(Library::Embeddings::DIMENSIONS) { random.rand - 0.5 }
      norm = Math.sqrt(raw.sum { |value| value * value })
      raw.map { |value| value / norm }
    end
  end

  it "degrades to plain title search, without error, when embeddings are unavailable" do
    allow(Library::Embeddings).to receive(:available?).and_return(false)
    book = create(:book, title: "Only Book")
    BookSearch.index_book!(book)

    get root_path(q: "Only Book", mode: "semantic")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Only Book")
  end

  def count_sql_queries
    count = 0
    callback = lambda do |*, payload|
      count += 1 unless payload[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    count
  end
end
