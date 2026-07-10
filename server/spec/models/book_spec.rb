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

  describe "#destroy" do
    let!(:book) { create(:book) }

    before { BookSearch.index_book!(book) }

    it "removes the book from the search index" do
      expect { book.destroy! }
        .to change { BookSearch.search(book.title).size }.from(1).to(0)
    end
  end
end
