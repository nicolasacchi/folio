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

    it "variant: 'original' bypasses the OCR companion, falling back to the raw file" do
      relative = "ocr/#{book.public_id}.ocr.pdf"
      companion = Library.base_root.join(relative)
      FileUtils.mkdir_p(companion.dirname)
      File.write(companion, "ocr'd bytes")
      pdf.update!(ocr_path: relative, ocr_sha256: "ocr-sha", ocr_size: 11, ocr_source_sha256: "src-sha")

      expect(pdf.delivery_path(variant: "original")).to eq(pdf.absolute_path)
      expect(pdf.delivery_sha256(variant: "original")).to eq(pdf.sha256)
      expect(pdf.delivery_size(variant: "original")).to eq(pdf.size)
      # variant: "auto" (the default) is unaffected.
      expect(pdf.delivery_path).to eq(pdf.ocr_absolute_path)
    end

    describe "variant: 'text'" do
      it "prefers the text-companion AZW3 once it's usable" do
        relative = "text/#{book.public_id}.azw3"
        kindle_text = Library.base_root.join(relative)
        FileUtils.mkdir_p(kindle_text.dirname)
        File.write(kindle_text, "azw3 bytes")
        text_relative = "text/#{book.public_id}.txt"
        FileUtils.mkdir_p(Library.base_root.join(text_relative).dirname)
        File.write(Library.base_root.join(text_relative), "plain text")
        pdf.update!(
          text_path: text_relative, text_source_sha256: "src-sha",
          text_kindle_path: relative, text_kindle_sha256: "text-kindle-sha", text_kindle_size: 10
        )

        expect(pdf.delivery_path(variant: "text")).to eq(kindle_text)
        expect(pdf.delivery_sha256(variant: "text")).to eq("text-kindle-sha")
        expect(pdf.delivery_size(variant: "text")).to eq(10)
        expect(pdf.delivery_format(variant: "text")).to eq("azw3")
      end

      it "falls back through the 'auto' chain when the AZW3 isn't usable yet" do
        expect(pdf).not_to be_text_kindle_usable
        expect(pdf.delivery_path(variant: "text")).to eq(pdf.absolute_path)
        expect(pdf.delivery_sha256(variant: "text")).to eq(pdf.sha256)
        expect(pdf.delivery_format(variant: "text")).to eq("pdf")
      end
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

  describe "#text_fresh? / #text_kindle_usable?" do
    let!(:pdf) { create(:book_file, :on_disk, book: book, format: "pdf", sha256: "src-sha") }

    def write_text_companion!(source_sha: "src-sha")
      relative = "text/#{book.public_id}.txt"
      FileUtils.mkdir_p(Library.base_root.join(relative).dirname)
      File.write(Library.base_root.join(relative), "plain text")
      pdf.update!(text_path: relative, text_source_sha256: source_sha)
    end

    it "is not fresh with no text companion" do
      expect(pdf).not_to be_text_fresh
      expect(pdf).not_to be_text_kindle_usable
    end

    it "is fresh once the companion matches the current source content sha and exists on disk" do
      write_text_companion!

      expect(pdf).to be_text_fresh
    end

    it "is stale once the source sha changes, even with a companion on disk" do
      write_text_companion!(source_sha: "old-sha")

      expect(pdf).not_to be_text_fresh
    end

    it "compares against the OCR companion's sha (not the raw sha) once the OCR companion is fresh" do
      ocr_relative = "ocr/#{book.public_id}.ocr.pdf"
      FileUtils.mkdir_p(Library.base_root.join(ocr_relative).dirname)
      File.write(Library.base_root.join(ocr_relative), "ocr'd bytes")
      pdf.update!(ocr_path: ocr_relative, ocr_sha256: "ocr-sha", ocr_source_sha256: "src-sha")

      expect(pdf.text_source_content_sha256).to eq("ocr-sha")

      write_text_companion!(source_sha: "src-sha") # matches the raw sha, not the (now current) OCR sha
      expect(pdf).not_to be_text_fresh

      write_text_companion!(source_sha: "ocr-sha")
      expect(pdf).to be_text_fresh
    end

    it "is usable only once the text companion is fresh AND the AZW3 build exists on disk" do
      write_text_companion!
      expect(pdf).not_to be_text_kindle_usable

      relative = "text/#{book.public_id}.azw3"
      FileUtils.mkdir_p(Library.base_root.join(relative).dirname)
      File.write(Library.base_root.join(relative), "azw3 bytes")
      pdf.update!(text_kindle_path: relative)

      expect(pdf).to be_text_kindle_usable
    end
  end

  describe "#text_source_content_sha256 engine awareness" do
    let!(:pdf) { create(:book_file, :on_disk, book: book, format: "pdf", sha256: "src-sha") }

    it "defaults to the row's own stored text_engine" do
      pdf.update!(text_engine: "deep")
      expect(pdf.text_source_content_sha256).to eq("src-sha")
    end

    it "'deep' always compares against the raw file's own sha, ignoring a fresh OCR companion" do
      ocr_relative = "ocr/#{book.public_id}.ocr.pdf"
      FileUtils.mkdir_p(Library.base_root.join(ocr_relative).dirname)
      File.write(Library.base_root.join(ocr_relative), "ocr'd bytes")
      pdf.update!(ocr_path: ocr_relative, ocr_sha256: "ocr-sha", ocr_source_sha256: "src-sha")

      expect(pdf.text_source_content_sha256("deep")).to eq("src-sha")
      expect(pdf.text_source_content_sha256("layer")).to eq("ocr-sha")
    end

    it "a 'deep' companion stays fresh across a re-OCR of the pdf's text layer (raw bytes unchanged)" do
      pdf.update!(text_engine: "deep", text_path: "text/#{book.public_id}.txt", text_source_sha256: "src-sha")
      FileUtils.mkdir_p(pdf.text_absolute_path.dirname)
      File.write(pdf.text_absolute_path, "deep text")
      expect(pdf).to be_text_fresh

      ocr_relative = "ocr/#{book.public_id}.ocr.pdf"
      FileUtils.mkdir_p(Library.base_root.join(ocr_relative).dirname)
      File.write(Library.base_root.join(ocr_relative), "ocr'd bytes")
      pdf.update!(ocr_path: ocr_relative, ocr_sha256: "new-ocr-sha", ocr_source_sha256: "src-sha")

      expect(pdf.reload).to be_text_fresh
    end

    it "a 'deep' companion goes stale once the raw file's own sha changes" do
      pdf.update!(text_engine: "deep", text_path: "text/#{book.public_id}.txt", text_source_sha256: "src-sha")
      FileUtils.mkdir_p(pdf.text_absolute_path.dirname)
      File.write(pdf.text_absolute_path, "deep text")
      expect(pdf).to be_text_fresh

      pdf.update!(sha256: "new-src-sha")

      expect(pdf.reload).not_to be_text_fresh
    end
  end

  describe "destroying a file with a text companion" do
    let!(:pdf) { create(:book_file, book: book, format: "pdf") }

    it "removes both the text companion and its Kindle AZW3 build from disk" do
      text_relative = "text/#{book.public_id}.txt"
      text_companion = Library.base_root.join(text_relative)
      FileUtils.mkdir_p(text_companion.dirname)
      File.write(text_companion, "plain text")

      azw3_relative = "text/#{book.public_id}.azw3"
      azw3 = Library.base_root.join(azw3_relative)
      File.write(azw3, "azw3 bytes")

      pdf.update!(text_path: text_relative, text_kindle_path: azw3_relative)

      pdf.destroy!

      expect(File.exist?(text_companion)).to be(false)
      expect(File.exist?(azw3)).to be(false)
    end

    it "does not raise when there is no text companion" do
      expect(pdf.text_path).to be_nil
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
