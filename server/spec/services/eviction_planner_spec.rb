require 'rails_helper'

RSpec.describe Library::EvictionPlanner do
  let(:device) { create(:device, free_bytes: free, total_bytes: 8_000_000_000, low_space_threshold_mb: 500) }
  let(:planner) { described_class.new(device) }

  def delivered!(book, at: 2.weeks.ago)
    create(:delivery, :delivered, book: book, device: device, delivered_at: at)
  end

  def sized_book(size)
    book = create(:book)
    create(:book_file, book: book, format: "azw3", size: size)
    book
  end

  context "with plenty of space" do
    let(:free) { 6_000_000_000 }

    it "plans nothing" do
      delivered!(sized_book(100.megabytes))
      expect(planner.plan).to be_empty
    end
  end

  context "with unknown storage" do
    let(:device) { create(:device) }

    it "plans nothing" do
      delivered!(sized_book(100.megabytes))
      expect(planner.plan).to be_empty
    end
  end

  context "when space is low" do
    # 300 MB free < 500 MB floor → needs ≥200 MB freed.
    let(:free) { 300.megabytes }

    it "prefers finished books, then never-opened, then dormant" do
      finished = sized_book(50.megabytes)
      create(:reading_state, book: finished, device: device, progress_percent: 98, content_mtime: 2.days.ago)
      delivered!(finished)

      untouched = sized_book(120.megabytes)
      delivered!(untouched)

      dormant = sized_book(80.megabytes)
      create(:reading_state, book: dormant, device: device, progress_percent: 40, content_mtime: 3.months.ago)
      delivered!(dormant)

      in_progress = sized_book(200.megabytes)
      create(:reading_state, book: in_progress, device: device, progress_percent: 40, content_mtime: 2.days.ago)
      delivered!(in_progress)

      reasons = planner.plan.map(&:reason)
      expect(reasons.first).to eq("finished")
      expect(reasons).to include("never opened")
      expect(planner.plan.map(&:book)).not_to include(in_progress)
    end

    it "stops once enough bytes are freed" do
      big = sized_book(400.megabytes)
      create(:reading_state, book: big, device: device, progress_percent: 100, content_mtime: 2.days.ago)
      delivered!(big)

      small = sized_book(10.megabytes)
      create(:reading_state, book: small, device: device, progress_percent: 100, content_mtime: 2.days.ago)
      delivered!(small)

      expect(planner.plan.map(&:book)).to eq([ big ])
    end

    it "ignores freshly delivered never-opened books" do
      fresh = sized_book(300.megabytes)
      delivered!(fresh, at: 1.day.ago)

      expect(planner.plan).to be_empty
    end

    it "accounts for the pending queue" do
      # 600 MB free is above the 500 MB floor, but a 300 MB pending
      # download will push it under.
      device.update!(free_bytes: 600.megabytes)
      create(:delivery, book: sized_book(300.megabytes), device: device)

      finished = sized_book(250.megabytes)
      create(:reading_state, book: finished, device: device, progress_percent: 100, content_mtime: 2.days.ago)
      delivered!(finished)

      expect(planner.plan.map(&:book)).to eq([ finished ])
    end

    it "never suggests books already queued for removal" do
      finished = sized_book(250.megabytes)
      create(:reading_state, book: finished, device: device, progress_percent: 100, content_mtime: 2.days.ago)
      delivered!(finished).request_eviction!("finished")

      expect(planner.plan).to be_empty
    end
  end
end
