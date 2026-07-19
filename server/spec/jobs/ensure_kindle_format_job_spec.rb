require 'rails_helper'

RSpec.describe EnsureKindleFormatJob do
  # Locks in that deriving the list from Conversion::SOURCE_PREFERENCE (see
  # the constant's comment) preserves the exact ordering this job had
  # before the two lists were consolidated.
  it "keeps the pre-consolidation source preference order" do
    expect(described_class::CONVERSION_SOURCE_PREFERENCE).to eq(
      %w[epub fb2 docx html htmlz odt rtf lit cbz cbr djvu]
    )
  end

  it "does nothing when the book already has a Kindle-openable file" do
    book = create(:book)
    create(:book_file, :on_disk, book: book, format: "azw3")

    expect { described_class.perform_now(book.id) }.not_to change(Conversion, :count)
  end

  it "queues a conversion from the richest available non-Kindle format" do
    book = create(:book)
    create(:book_file, :on_disk, book: book, format: "html")
    epub = create(:book_file, :on_disk, book: book, format: "epub")

    expect { described_class.perform_now(book.id) }.to change(Conversion, :count).by(1)

    conversion = book.conversions.sole
    expect(conversion.book_file).to eq(epub)
    expect(conversion.target_format).to eq("mobi")
  end

  it "does nothing when the book has no convertible source file" do
    book = create(:book)

    expect { described_class.perform_now(book.id) }.not_to change(Conversion, :count)
  end

  it "treats losing the create! race to another worker as a no-op instead of raising" do
    book = create(:book)
    create(:book_file, :on_disk, book: book, format: "epub")
    # Simulate two workers both passing the active-scope pre-check before
    # either commits: book.conversions.create! is stubbed to raise the same
    # error the partial unique index (index_conversions_on_active_book_target)
    # raises when a concurrent worker's insert lands first.
    allow(Book).to receive(:find_by).with(id: book.id).and_return(book)
    allow(book.conversions).to receive(:create!).and_raise(
      ActiveRecord::RecordNotUnique.new("UNIQUE constraint failed: index_conversions_on_active_book_target")
    )

    expect { described_class.perform_now(book.id) }.not_to raise_error
    expect(Conversion.count).to eq(0)
    expect(ConvertBookJob).not_to have_been_enqueued
  end
end
