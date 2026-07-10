require 'rails_helper'

RSpec.describe Conversion, type: :model do
  let!(:book) { create(:book) }
  let!(:source) { create(:book_file, book: book, format: "epub") }

  it "rejects converting a file to its own format" do
    conversion = build(:conversion, book: book, book_file: source, target_format: "epub")
    expect(conversion).not_to be_valid
  end

  it "tracks lifecycle transitions with timestamps" do
    conversion = create(:conversion, book: book, book_file: source, target_format: "azw3")

    conversion.mark_running!
    expect(conversion).to be_running
    expect(conversion.started_at).to be_present

    conversion.mark_failed!("boom")
    expect(conversion).to be_failed
    expect(conversion.error).to eq("boom")
    expect(conversion.finished_at).to be_present
  end
end
