require 'rails_helper'

RSpec.describe Book, type: :model do
  describe "#kindle_file" do
    let!(:book) { create(:book) }
    let!(:epub) { create(:book_file, book: book, format: "epub") }

    it "is nil when only non-Kindle formats exist" do
      expect(book.kindle_file).to be_nil
    end

    context "with several Kindle-ready formats" do
      let!(:pdf) { create(:book_file, book: book, format: "pdf") }
      let!(:azw3) { create(:book_file, book: book, format: "azw3") }

      it "prefers azw3 over pdf" do
        expect(book.kindle_file).to eq(azw3)
      end
    end
  end

  describe "#ocr_candidate_file" do
    let!(:book) { create(:book) }

    it "is nil when the book has no pdf file" do
      create(:book_file, book: book, format: "epub")
      expect(book.ocr_candidate_file).to be_nil
    end

    it "is the pdf book_file when present and available" do
      pdf = create(:book_file, book: book, format: "pdf")
      expect(book.ocr_candidate_file).to eq(pdf)
    end

    it "is nil when the pdf file is unavailable (e.g. missing from a scan)" do
      create(:book_file, book: book, format: "pdf", available: false)
      expect(book.ocr_candidate_file).to be_nil
    end
  end

  describe "#text_companion_source_file" do
    let!(:book) { create(:book) }

    it "is nil when the book has no pdf file" do
      create(:book_file, book: book, format: "epub")
      expect(book.text_companion_source_file).to be_nil
    end

    it "is the pdf book_file when it's the book's Kindle-delivery file" do
      pdf = create(:book_file, book: book, format: "pdf")
      expect(book.text_companion_source_file).to eq(pdf)
    end

    it "is nil when a richer Kindle format already exists (pdf isn't the kindle_file)" do
      create(:book_file, book: book, format: "pdf")
      create(:book_file, book: book, format: "azw3")
      expect(book.text_companion_source_file).to be_nil
    end
  end

  describe "#queue_text_companion!" do
    let!(:book) { create(:book) }

    it "is nil (and queues nothing) when there is no pdf source" do
      create(:book_file, book: book, format: "epub")

      expect { expect(book.queue_text_companion!).to be_nil }
        .not_to have_enqueued_job(TextCompanionJob)
    end

    it "creates a Conversion and queues TextCompanionJob for an eligible pdf" do
      create(:book_file, book: book, format: "pdf")

      conversion = nil
      expect {
        conversion = book.queue_text_companion!
      }.to have_enqueued_job(TextCompanionJob).with { |id| conversion&.id == id }

      expect(conversion).to be_a(Conversion)
      expect(conversion).to be_text
      expect(conversion).to be_pending
    end

    it "returns the existing active conversion instead of queueing a second one" do
      pdf = create(:book_file, book: book, format: "pdf")
      existing = create(:conversion, :text, book: book, book_file: pdf, status: "running")

      expect { expect(book.queue_text_companion!).to eq(existing) }
        .not_to have_enqueued_job(TextCompanionJob)
    end

    it "is nil (and queues nothing) once the text-companion AZW3 is already usable" do
      pdf = create(:book_file, :on_disk, book: book, format: "pdf")
      relative = "text/#{book.public_id}.azw3"
      FileUtils.mkdir_p(Library.base_root.join(relative).dirname)
      File.write(Library.base_root.join(relative), "azw3 bytes")
      pdf.update!(
        text_path: "text/#{book.public_id}.txt", text_source_sha256: pdf.sha256,
        text_kindle_path: relative
      )
      FileUtils.mkdir_p(Library.base_root.join(pdf.text_path).dirname)
      File.write(Library.base_root.join(pdf.text_path), "text")

      expect { expect(book.queue_text_companion!).to be_nil }
        .not_to have_enqueued_job(TextCompanionJob)
    end
  end

  describe "#conversion_failed_without_deliverable?" do
    let!(:book) { create(:book) }
    let!(:source) { create(:book_file, book: book, format: "epub") }

    it "is false when there are no conversions at all" do
      expect(book.conversion_failed_without_deliverable?).to be false
    end

    it "is true once a conversion has failed and no Kindle-ready file exists" do
      create(:conversion, book: book, book_file: source, target_format: "azw3", status: "failed")
      expect(book.conversion_failed_without_deliverable?).to be true
    end

    it "is false when a failed conversion coexists with a good Kindle-ready file" do
      create(:conversion, book: book, book_file: source, target_format: "azw3", status: "failed")
      create(:book_file, book: book, format: "azw3")
      expect(book.reload.conversion_failed_without_deliverable?).to be false
    end
  end

  describe ".search" do
    let!(:whale_book) { create(:book, title: "The Whale", author: "H. Melville") }
    let!(:other_book) { create(:book, title: "Cooking for Two") }

    before do
      BookSearch.index_book!(whale_book, fulltext: "harpoons and rigging on the open sea")
      BookSearch.index_book!(other_book, fulltext: "recipes with garlic")
    end

    it "finds books by title" do
      expect(Book.search("whale").map(&:book)).to eq([ whale_book ])
    end

    it "finds books by fulltext and returns a highlighted snippet" do
      hits = Book.search("harpoon")
      expect(hits.map(&:book)).to eq([ whale_book ])
      expect(hits.first.snippet).to include("<mark>harpoon")
    end

    it "returns nothing for unmatched terms" do
      expect(Book.search("submarine")).to be_empty
    end
  end

  describe ".keep_reading_for" do
    let!(:user) { create(:user) }
    let!(:device) { create(:device) }
    let!(:kindle_book) { create(:book, title: "Kindle only") }
    let!(:web_book) { create(:book, title: "Web only") }
    let!(:both_book) { create(:book, title: "Both") }

    before do
      create(:reading_state, book: kindle_book, device: device, progress_percent: 40, content_mtime: 3.days.ago)
      create(:reader_position, book: web_book, user: user, percent: 25, updated_at: 2.days.ago)
      create(:reading_state, book: both_book, device: device, progress_percent: 50, content_mtime: 5.days.ago)
      create(:reader_position, book: both_book, user: user, percent: 55, updated_at: 1.day.ago)
    end

    it "merges web and kindle unfinished positions, deduping by most recent activity" do
      rows = Book.keep_reading_for(user, limit: 10)
      books = rows.map(&:first)
      expect(books).to eq([ both_book, web_book, kindle_book ])

      both_entry = rows.find { |book, _| book == both_book }.last
      expect(both_entry.source_label).to eq("Web")
      expect(both_entry.progress_percent).to eq(55)

      kindle_entry = rows.find { |book, _| book == kindle_book }.last
      expect(kindle_entry.source_label).to eq(device.name)
    end

    it "drops finished web positions and finished kindle progress" do
      create(:reader_position, book: create(:book), user: user, percent: 99)
      finished = create(:book)
      create(:reading_state, book: finished, device: device, progress_percent: 99, content_mtime: Time.current)

      books = Book.keep_reading_for(user, limit: 20).map(&:first)
      expect(books).not_to include(finished)
      expect(books.map { |b| b.reader_positions.find_by(user: user)&.percent }.compact).not_to include(99)
    end

    it "respects the limit" do
      expect(Book.keep_reading_for(user, limit: 2).size).to eq(2)
    end
  end

  describe "category" do
    it "accepts a nil, single-segment, or two-segment category" do
      expect(build(:book, category: nil)).to be_valid
      expect(build(:book, category: "fiction")).to be_valid
      expect(build(:book, category: "fiction/sf")).to be_valid
      expect(build(:book, category: "_inbox")).to be_valid
    end

    it "rejects author/title-shaped or uppercase values" do
      expect(build(:book, category: "Fiction/SF")).not_to be_valid
      expect(build(:book, category: "fiction/sf/extra")).not_to be_valid
      expect(build(:book, category: "fiction sf")).not_to be_valid
    end

    describe "#category_parts / #category_root / #display_category" do
      it "splits a two-segment category" do
        book = build(:book, category: "fiction/sf")
        expect(book.category_parts).to eq(%w[fiction sf])
        expect(book.category_root).to eq("fiction")
        expect(book.display_category).to eq("fiction/sf")
      end

      it "handles a blank category" do
        book = build(:book, category: nil)
        expect(book.category_parts).to eq([])
        expect(book.category_root).to be_nil
        expect(book.display_category).to eq("Uncategorized")
      end
    end

    describe ".in_category / .in_category_root" do
      let!(:sf_book) { create(:book, category: "fiction/sf") }
      let!(:literary_book) { create(:book, category: "fiction/literary") }
      let!(:history_book) { create(:book, category: "nonfiction/history") }

      it ".in_category matches the exact string" do
        expect(Book.in_category("fiction/sf")).to contain_exactly(sf_book)
      end

      it ".in_category_root matches the root segment or any of its subcategories" do
        expect(Book.in_category_root("fiction")).to contain_exactly(sf_book, literary_book)
      end
    end
  end

  describe "#destroy" do
    let!(:book) { create(:book) }

    before { BookSearch.index_book!(book) }

    it "removes the book from the search index" do
      expect { book.destroy! }
        .to change { BookSearch.search(book.title).size }.from(1).to(0)
    end

    it "destroys cleanly when a file has conversion history" do
      # book_files is declared before conversions on Book, so its
      # dependent: :destroy callback runs first — this only stays clean
      # because BookFile has its own has_many :conversions, dependent: :destroy.
      file = create(:book_file, book: book)
      create(:conversion, book: book, book_file: file)

      expect { book.destroy! }.not_to raise_error
    end
  end
end
