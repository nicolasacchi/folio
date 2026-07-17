require 'rails_helper'

RSpec.describe BookFile, type: :model do
  let!(:book) { create(:book) }
  let!(:book_file) { create(:book_file, book: book, format: "epub") }

  it "rejects duplicate formats per book" do
    duplicate = build(:book_file, book: book, format: "epub")
    expect(duplicate).not_to be_valid
  end

  it "rejects unknown formats" do
    expect(build(:book_file, book: book, format: "exe")).not_to be_valid
  end

  describe "#kindle_ready?" do
    it "is false for epub and true for azw3" do
      expect(book_file.kindle_ready?).to be(false)
      expect(build(:book_file, format: "azw3").kindle_ready?).to be(true)
    end
  end

  describe "destroying a file that sourced a conversion" do
    # conversions.book_file_id is NOT NULL with no ON DELETE — destroying
    # the source file on its own (book survives, e.g. Library::Scan.prune_missing!)
    # must cascade to its conversions, not just Book's own dependent: :destroy
    # (which only fires when the whole book goes and wouldn't save this row anyway).
    it "destroys its conversions instead of raising a foreign key violation" do
      conversion = create(:conversion, book: book, book_file: book_file)

      expect { book_file.destroy! }.not_to raise_error
      expect(Conversion.exists?(conversion.id)).to be(false)
    end
  end
end
