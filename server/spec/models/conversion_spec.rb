require 'rails_helper'

RSpec.describe Conversion, type: :model do
  let!(:book) { create(:book) }
  let!(:source) { create(:book_file, book: book, format: "epub") }

  it "rejects converting a file to its own format" do
    conversion = build(:conversion, book: book, book_file: source, target_format: "epub")
    expect(conversion).not_to be_valid
  end

  it "lets the database reject a second active conversion for the same book/target (index_conversions_on_active_book_target)" do
    create(:conversion, book: book, book_file: source, target_format: "azw3", status: "pending")

    expect {
      Conversion.create!(book: book, book_file: source, target_format: "azw3", status: "running")
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "allows a second conversion for the same book/target once the first is no longer active" do
    create(:conversion, book: book, book_file: source, target_format: "azw3", status: "completed")

    expect {
      Conversion.create!(book: book, book_file: source, target_format: "azw3", status: "pending")
    }.not_to raise_error
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

  describe ".sweep_stuck!" do
    it "fails running conversions whose started_at is older than the threshold" do
      stuck = create(:conversion, book: book, book_file: source, target_format: "azw3", status: "running",
        started_at: 2.hours.ago)

      expect(Conversion.sweep_stuck!(older_than: 1.hour)).to eq(1)
      expect(stuck.reload).to be_failed
      expect(stuck.error).to eq("conversion timed out (worker stopped)")
      expect(stuck.finished_at).to be_present
    end

    it "treats a running conversion with no started_at as stuck too" do
      stuck = create(:conversion, book: book, book_file: source, target_format: "azw3", status: "running",
        started_at: nil)

      expect(Conversion.sweep_stuck!(older_than: 1.hour)).to eq(1)
      expect(stuck.reload).to be_failed
    end

    it "leaves fresh running conversions alone" do
      fresh = create(:conversion, book: book, book_file: source, target_format: "azw3", status: "running",
        started_at: 1.minute.ago)

      expect(Conversion.sweep_stuck!(older_than: 1.hour)).to eq(0)
      expect(fresh.reload).to be_running
    end

    it "leaves completed and pending conversions alone" do
      completed = create(:conversion, book: book, book_file: source, target_format: "azw3", status: "completed",
        started_at: 2.hours.ago, finished_at: 1.hour.ago)
      pending = create(:conversion, book: book, book_file: source, target_format: "mobi", status: "pending")

      expect(Conversion.sweep_stuck!(older_than: 1.hour)).to eq(0)
      expect(completed.reload).to be_completed
      expect(pending.reload).to be_pending
    end
  end
end
