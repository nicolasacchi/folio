require 'rails_helper'

RSpec.describe SweepStuckConversionsJob do
  it "delegates to Conversion.sweep_stuck! with the default threshold" do
    expect(Conversion).to receive(:sweep_stuck!).with(no_args)

    described_class.perform_now
  end

  it "fails a conversion stuck running past STUCK_AFTER" do
    book = create(:book)
    source = create(:book_file, book: book, format: "epub")
    stuck = create(:conversion, book: book, book_file: source, target_format: "azw3", status: "running",
      started_at: (Conversion::STUCK_AFTER + 1.minute).ago)

    described_class.perform_now

    expect(stuck.reload).to be_failed
  end
end
