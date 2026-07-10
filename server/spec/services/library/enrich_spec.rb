require 'rails_helper'

RSpec.describe Library::Enrich do
  let(:book) { create(:book, title: "The Salt Road", author: "Ada Author", description: nil, published_year: nil) }

  it "fills only blank fields from the first provider that matches" do
    allow(Library::Enrich::OpenLibrary).to receive(:lookup)
      .with(title: "The Salt Road", author: "Ada Author")
      .and_return({ description: "A journey.", published_year: 2011 })

    expect(described_class.call(book)).to eq(:enriched)
    book.reload
    expect(book.description).to eq("A journey.")
    expect(book.published_year).to eq(2011)
    expect(book.enrichment_source).to eq("openlibrary")
    expect(book.enriched_at).to be_present
  end

  it "rejects implausible publication years from providers" do
    allow(Library::Enrich::OpenLibrary).to receive(:lookup).and_return({ description: "Text.", published_year: 101 })

    described_class.call(book)

    expect(book.reload.published_year).to be_nil
    expect(book.description).to eq("Text.")
  end

  it "does not overwrite an existing description" do
    book.update!(description: "Original text.")
    allow(Library::Enrich::OpenLibrary).to receive(:lookup).and_return({ description: "Provider text.", published_year: 2011 })

    described_class.call(book)

    expect(book.reload.description).to eq("Original text.")
    expect(book.published_year).to eq(2011)
  end

  it "falls back to the next provider and records a total miss" do
    allow(Library::Enrich::OpenLibrary).to receive(:lookup).and_return(nil)
    allow(Library::Enrich::GoogleBooks).to receive(:lookup).and_return(nil)

    expect(described_class.call(book)).to eq(:no_match)
    expect(book.reload.enrichment_source).to eq("none")
  end

  describe ".plausible_match?" do
    it "accepts close titles with matching author surname" do
      expect(described_class.plausible_match?(
        book_title: "Il nome della rosa", book_author: "Umberto Eco",
        found_title: "Il nome della rosa: romanzo", found_authors: [ "Eco, Umberto" ]
      )).to be(true)
    end

    it "rejects unrelated titles" do
      expect(described_class.plausible_match?(
        book_title: "Il nome della rosa", book_author: "Umberto Eco",
        found_title: "A Field Guide to Roses", found_authors: [ "Someone Else" ]
      )).to be(false)
    end

    it "rejects a matching title from a different author" do
      expect(described_class.plausible_match?(
        book_title: "Collected Poems", book_author: "Mary Oliver",
        found_title: "Collected Poems", found_authors: [ "Philip Larkin" ]
      )).to be(false)
    end
  end
end
