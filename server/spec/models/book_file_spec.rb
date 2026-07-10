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
end
