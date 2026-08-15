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

  describe "destroying a file with a prepared delivery copy" do
    it "removes the prepared copy from disk too" do
      relative = "prepared/#{book.public_id}.mobi"
      prepared = Library.base_root.join(relative)
      FileUtils.mkdir_p(prepared.dirname)
      File.write(prepared, "prepared bytes")
      book_file.update!(prepared_path: relative)

      book_file.destroy!

      expect(File.exist?(prepared)).to be(false)
    end

    it "does not raise when there is no prepared copy" do
      expect(book_file.prepared_path).to be_nil
      expect { book_file.destroy! }.not_to raise_error
    end

    it "does not raise when the prepared copy is already gone from disk" do
      book_file.update!(prepared_path: "prepared/#{book.public_id}.mobi")

      expect { book_file.destroy! }.not_to raise_error
    end
  end

  describe "#ocr_fresh? / #read_source_path" do
    let!(:pdf) { create(:book_file, :on_disk, book: book, format: "pdf", sha256: "src-sha") }

    it "is not fresh with no OCR companion, and reads the raw file" do
      expect(pdf).not_to be_ocr_fresh
      expect(pdf.read_source_path).to eq(pdf.absolute_path)
    end

    it "is fresh once the companion matches the current sha256 and exists on disk" do
      relative = "ocr/#{book.public_id}.ocr.pdf"
      companion = Library.base_root.join(relative)
      FileUtils.mkdir_p(companion.dirname)
      File.write(companion, "ocr'd bytes")
      pdf.update!(ocr_path: relative, ocr_source_sha256: "src-sha")

      expect(pdf).to be_ocr_fresh
      expect(pdf.read_source_path).to eq(pdf.ocr_absolute_path)
    end

    it "is stale once the source sha changes, even with a companion on disk" do
      relative = "ocr/#{book.public_id}.ocr.pdf"
      companion = Library.base_root.join(relative)
      FileUtils.mkdir_p(companion.dirname)
      File.write(companion, "ocr'd bytes")
      pdf.update!(ocr_path: relative, ocr_source_sha256: "old-sha")

      expect(pdf).not_to be_ocr_fresh
      expect(pdf.read_source_path).to eq(pdf.absolute_path)
    end

    it "is stale when the companion path is recorded but missing from disk" do
      pdf.update!(ocr_path: "ocr/#{book.public_id}.ocr.pdf", ocr_source_sha256: "src-sha")

      expect(pdf).not_to be_ocr_fresh
    end
  end

  describe "#delivery_path / #delivery_sha256 / #delivery_size precedence" do
    let!(:pdf) { create(:book_file, :on_disk, book: book, format: "pdf", sha256: "src-sha") }

    it "falls back to the raw file when neither a prepared nor an OCR copy is fresh" do
      expect(pdf.delivery_path).to eq(pdf.absolute_path)
      expect(pdf.delivery_sha256).to eq(pdf.sha256)
      expect(pdf.delivery_size).to eq(pdf.size)
    end

    it "prefers the OCR companion over the raw file once it's fresh" do
      relative = "ocr/#{book.public_id}.ocr.pdf"
      companion = Library.base_root.join(relative)
      FileUtils.mkdir_p(companion.dirname)
      File.write(companion, "ocr'd bytes")
      pdf.update!(ocr_path: relative, ocr_sha256: "ocr-sha", ocr_size: 11, ocr_source_sha256: "src-sha")

      expect(pdf.delivery_path).to eq(pdf.ocr_absolute_path)
      expect(pdf.delivery_sha256).to eq("ocr-sha")
      expect(pdf.delivery_size).to eq(11)
    end

    it "still prefers the prepared copy over a fresh OCR companion" do
      prepared_relative = "prepared/#{book.public_id}.pdf"
      prepared = Library.base_root.join(prepared_relative)
      FileUtils.mkdir_p(prepared.dirname)
      File.write(prepared, "prepared bytes")
      pdf.update!(prepared_path: prepared_relative, prepared_sha256: "prepared-sha",
        prepared_size: 14, prepared_source_sha256: "src-sha")

      ocr_relative = "ocr/#{book.public_id}.ocr.pdf"
      ocr = Library.base_root.join(ocr_relative)
      FileUtils.mkdir_p(ocr.dirname)
      File.write(ocr, "ocr'd bytes")
      pdf.update!(ocr_path: ocr_relative, ocr_sha256: "ocr-sha", ocr_size: 11, ocr_source_sha256: "src-sha")

      expect(pdf.delivery_path).to eq(pdf.prepared_absolute_path)
      expect(pdf.delivery_sha256).to eq("prepared-sha")
      expect(pdf.delivery_size).to eq(14)
    end
  end

  describe "destroying a file with an OCR companion" do
    let!(:pdf) { create(:book_file, book: book, format: "pdf") }

    it "removes the OCR companion from disk too" do
      relative = "ocr/#{book.public_id}.ocr.pdf"
      companion = Library.base_root.join(relative)
      FileUtils.mkdir_p(companion.dirname)
      File.write(companion, "ocr'd bytes")
      pdf.update!(ocr_path: relative)

      pdf.destroy!

      expect(File.exist?(companion)).to be(false)
    end

    it "does not raise when there is no OCR companion" do
      expect(pdf.ocr_path).to be_nil
      expect { pdf.destroy! }.not_to raise_error
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
