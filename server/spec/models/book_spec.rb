require 'rails_helper'

RSpec.describe Book, type: :model do
  describe "#kindle_file" do
    let!(:book) { create(:book) }
    let!(:epub) { create(:book_file, book: book, format: "epub") }

    it "is nil when only non-Kindle formats exist" do
      expect(book.kindle_file).to be_nil
    end

    context "with several Kindle-ready formats" do
      let!(:pdf) { create(:book_file, book: book, format: "pdf") }
      let!(:azw3) { create(:book_file, book: book, format: "azw3") }

      it "prefers azw3 over pdf" do
        expect(book.kindle_file).to eq(azw3)
      end
    end
  end

  describe ".search" do
    let!(:whale_book) { create(:book, title: "The Whale", author: "H. Melville") }
    let!(:other_book) { create(:book, title: "Cooking for Two") }

    before do
      BookSearch.index_book!(whale_book, fulltext: "harpoons and rigging on the open sea")
      BookSearch.index_book!(other_book, fulltext: "recipes with garlic")
    end

    it "finds books by title" do
      expect(Book.search("whale").map(&:book)).to eq([ whale_book ])
    end

    it "finds books by fulltext and returns a highlighted snippet" do
      hits = Book.search("harpoon")
      expect(hits.map(&:book)).to eq([ whale_book ])
      expect(hits.first.snippet).to include("<mark>harpoon")
    end

    it "returns nothing for unmatched terms" do
      expect(Book.search("submarine")).to be_empty
    end
  end

  describe "category" do
    it "accepts a nil, single-segment, or two-segment category" do
      expect(build(:book, category: nil)).to be_valid
      expect(build(:book, category: "fiction")).to be_valid
      expect(build(:book, category: "fiction/sf")).to be_valid
      expect(build(:book, category: "_inbox")).to be_valid
    end

    it "rejects author/title-shaped or uppercase values" do
      expect(build(:book, category: "Fiction/SF")).not_to be_valid
      expect(build(:book, category: "fiction/sf/extra")).not_to be_valid
      expect(build(:book, category: "fiction sf")).not_to be_valid
    end

    describe "#category_parts / #category_root / #display_category" do
      it "splits a two-segment category" do
        book = build(:book, category: "fiction/sf")
        expect(book.category_parts).to eq(%w[fiction sf])
        expect(book.category_root).to eq("fiction")
        expect(book.display_category).to eq("fiction/sf")
      end

      it "handles a blank category" do
        book = build(:book, category: nil)
        expect(book.category_parts).to eq([])
        expect(book.category_root).to be_nil
        expect(book.display_category).to eq("Uncategorized")
      end
    end

    describe ".in_category / .in_category_root" do
      let!(:sf_book) { create(:book, category: "fiction/sf") }
      let!(:literary_book) { create(:book, category: "fiction/literary") }
      let!(:history_book) { create(:book, category: "nonfiction/history") }

      it ".in_category matches the exact string" do
        expect(Book.in_category("fiction/sf")).to contain_exactly(sf_book)
      end

      it ".in_category_root matches the root segment or any of its subcategories" do
        expect(Book.in_category_root("fiction")).to contain_exactly(sf_book, literary_book)
      end
    end
  end

  describe "#destroy" do
    let!(:book) { create(:book) }

    before { BookSearch.index_book!(book) }

    it "removes the book from the search index" do
      expect { book.destroy! }
        .to change { BookSearch.search(book.title).size }.from(1).to(0)
    end
  end
end
