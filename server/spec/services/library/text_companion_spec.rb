require "rails_helper"

RSpec.describe Library::TextCompanion do
  let(:book) { build(:book, public_id: "abc123") }

  it "roots the companion directory alongside prepared/ocr under base_root" do
    expect(described_class.root).to eq(Library.base_root.join("text"))
  end

  it "names the plain-text companion after the book's public_id" do
    expect(described_class.text_path(book)).to eq(described_class.root.join("abc123.txt"))
  end

  it "names the Kindle AZW3 build after the book's public_id" do
    expect(described_class.kindle_path(book)).to eq(described_class.root.join("abc123.azw3"))
  end
end
