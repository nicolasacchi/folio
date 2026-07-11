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
