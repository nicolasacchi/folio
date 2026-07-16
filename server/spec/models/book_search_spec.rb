require 'rails_helper'

RSpec.describe BookSearch do
  describe ".match_expression" do
    it "quotes every term and adds prefix matching to the last one" do
      expect(described_class.match_expression("silver mount")).to eq('"silver" "mount"*')
    end

    it "neutralizes FTS5 query syntax in user input" do
      expect(described_class.match_expression('title: OR "boom" NEAR(x)'))
        .to eq('"title" "OR" "boom" "NEAR" "x"*')
    end

    it "is nil for input without word characters" do
      expect(described_class.match_expression("  !?* ")).to be_nil
    end
  end

  describe ".search" do
    let!(:book) { create(:book, title: "Cranes of Kyōto") }

    before { described_class.index_book!(book) }

    it "matches with diacritics removed" do
      expect(described_class.search("kyoto").map { |hit| hit[:book_id] }).to eq([ book.id ])
    end

    it "does not raise on hostile input" do
      expect { described_class.search('") OR 1=1 --') }.not_to raise_error
    end

    context "with scope: :metadata" do
      let!(:fulltext_only) { create(:book, title: "Unrelated Title") }

      before { described_class.index_book!(fulltext_only, fulltext: "hidden cranes in the text body") }

      it "matches titles but not fulltext" do
        ids = described_class.search("cranes", scope: :metadata).map { |hit| hit[:book_id] }
        expect(ids).to eq([ book.id ])
      end

      it "still finds fulltext matches in the default scope" do
        ids = described_class.search("cranes").map { |hit| hit[:book_id] }
        expect(ids).to contain_exactly(book.id, fulltext_only.id)
      end

      it "matches authors and series" do
        authored = create(:book, title: "Zzz", author: "Maria Cranebuilder", series: "The Marsh")
        described_class.index_book!(authored)

        expect(described_class.search("cranebuilder", scope: :metadata).map { |h| h[:book_id] })
          .to eq([ authored.id ])
        expect(described_class.search("marsh", scope: :metadata).map { |h| h[:book_id] })
          .to eq([ authored.id ])
      end

      it "returns no snippet" do
        hit = described_class.search("cranes", scope: :metadata).first
        expect(hit[:snippet]).to be_nil
      end

      it "survives hostile input" do
        expect { described_class.search('") OR 1=1 --', scope: :metadata) }.not_to raise_error
      end
    end
  end

  describe ".index_book!" do
    let!(:book) { create(:book, title: "Original") }

    it "keeps the stored fulltext when reindexing metadata only" do
      described_class.index_book!(book, fulltext: "some extracted words")
      book.update!(title: "Renamed")
      described_class.index_book!(book)

      expect(described_class.search("extracted").map { |hit| hit[:book_id] }).to eq([ book.id ])
      expect(described_class.search("renamed").map { |hit| hit[:book_id] }).to eq([ book.id ])
    end

    it "indexes the category's raw key and human labels so either finds the book" do
      shelved = create(:book, title: "Nebula Run", category: "fiction/sf")
      described_class.index_book!(shelved)

      expect(described_class.search("sf", scope: :metadata).map { |hit| hit[:book_id] }).to eq([ shelved.id ])
      expect(described_class.search("Fantascienza", scope: :metadata).map { |hit| hit[:book_id] })
        .to eq([ shelved.id ])
      expect(described_class.search("Fiction", scope: :metadata).map { |hit| hit[:book_id] }).to eq([ shelved.id ])
    end

    it "does not blow up indexing a book with no category" do
      bare = create(:book, title: "No Shelf", category: nil)
      expect { described_class.index_book!(bare) }.not_to raise_error
      expect(described_class.search("shelf", scope: :metadata).map { |hit| hit[:book_id] }).to eq([ bare.id ])
    end
  end

  describe "legacy schema migration" do
    let(:legacy_sql) do
      <<~SQL
        CREATE VIRTUAL TABLE book_search USING fts5(
          book_id UNINDEXED, title, author, series, description, fulltext,
          tokenize = 'unicode61 remove_diacritics 2'
        );
      SQL
    end

    # The suite-shared db file runs in WAL mode (see open_database), which
    # leaves -wal/-shm sidecars alongside it; wiping only the main file
    # leaves them behind mismatched against the fresh file written below
    # and SQLite refuses to open the result ("disk I/O error"). All specs
    # in this group nuke every sidecar, both before writing a legacy file
    # and afterwards, so later examples reopen a clean current-shape db.
    def wipe_search_db!
      described_class.reset!
      FileUtils.rm_f(Dir.glob("#{described_class.db_path}*"))
    end

    def write_legacy_db!(rows)
      FileUtils.mkdir_p(described_class.db_path.dirname)
      db = SQLite3::Database.new(described_class.db_path.to_s)
      db.execute(legacy_sql)
      rows.each do |row|
        db.execute(
          "INSERT INTO book_search (book_id, title, author, series, description, fulltext) VALUES (?, ?, ?, ?, ?, ?)",
          row
        )
      end
      db.close
    end

    after { wipe_search_db! }

    it "rebuilds the table on first touch, keeping every legacy row with a blank category" do
      book = create(:book, title: "Cranes of Kyōto", category: "fiction/sf")

      wipe_search_db!
      write_legacy_db!([ [ book.id, "Stale Title", "", "", "", "old extracted fulltext" ] ])
      described_class.reset!

      # The swap is a pure-SQL copy (the production index is gigabytes of
      # fulltext, so nothing may flow through Ruby at boot): legacy rows
      # keep their stored metadata and an empty category until the next
      # index_book! touches them.
      expect(described_class.search("old extracted").map { |hit| hit[:book_id] }).to eq([ book.id ])
      expect(described_class.search("Stale Title").map { |hit| hit[:book_id] }).to eq([ book.id ])
      expect(described_class.search("Fantascienza", scope: :metadata)).to eq([])

      # A reindex refreshes metadata + category while the stored fulltext
      # keeps riding along (index_book! carries it over via stored_fulltext).
      described_class.index_book!(book)
      expect(described_class.search("Fantascienza", scope: :metadata).map { |hit| hit[:book_id] }).to eq([ book.id ])
      expect(described_class.search("old extracted").map { |hit| hit[:book_id] }).to eq([ book.id ])
    end

    it "keeps legacy rows whose book no longer exists without raising" do
      wipe_search_db!
      write_legacy_db!([ [ 0, "Orphan", "", "", "", "" ] ])
      described_class.reset!

      expect { described_class.search("orphan") }.not_to raise_error
      expect(described_class.search("orphan").map { |hit| hit[:book_id] }).to eq([ 0 ])
    end
  end

  describe ".migrate_from_primary!" do
    let(:primary) { ActiveRecord::Base.connection }

    before do
      primary.execute(BookSearch::SCHEMA_SQL)
      primary.execute(<<~SQL)
        INSERT INTO book_search (book_id, title, author, series, description, fulltext)
        VALUES (1, 'Legacy One', '', '', '', 'old crawling text'),
               (2, 'Legacy Two', '', '', '', '')
      SQL
    end

    it "moves legacy rows over in batches, skips duplicates, drops the table" do
      described_class.index_book!(Book.new(id: 2, title: "Already Here"), fulltext: "fresh")

      moved = described_class.migrate_from_primary!(batch_size: 1)

      expect(moved).to eq(1)
      expect(described_class.search("crawling").map { |hit| hit[:book_id] }).to eq([ 1 ])
      # The row indexed after the split is authoritative, not the legacy copy.
      expect(described_class.search("fresh").map { |hit| hit[:book_id] }).to eq([ 2 ])
      expect(primary.select_value("SELECT 1 FROM sqlite_master WHERE name = 'book_search'")).to be_nil
    end

    it "is a no-op without a legacy table" do
      primary.execute("DROP TABLE book_search")
      expect(described_class.migrate_from_primary!).to eq(0)
    end
  end
end
