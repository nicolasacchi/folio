require 'rails_helper'

RSpec.describe ConvertBookJob do
  let(:book) { create(:book) }
  let(:source) { create(:book_file, book: book, format: "epub") }
  let(:conversion) { create(:conversion, book: book, book_file: source, target_format: "azw3") }

  it "marks the conversion failed without re-raising when Calibre reports an expected conversion error" do
    allow(Calibre).to receive(:convert).and_raise(Calibre::Error, "boom")

    expect { described_class.perform_now(conversion.id) }.not_to raise_error

    expect(conversion.reload).to be_failed
    expect(conversion.error).to eq("boom")
  end

  it "marks the conversion failed and re-raises an unexpected error so the job can be retried" do
    allow(Calibre).to receive(:convert).and_raise(StandardError, "disk exploded")

    expect { described_class.perform_now(conversion.id) }.to raise_error(StandardError, "disk exploded")

    expect(conversion.reload).to be_failed
    expect(conversion.error).to eq("disk exploded")
  end
end
