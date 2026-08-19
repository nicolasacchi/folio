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

  describe ".extract_text" do
    def stub_pdftotext(success:, stdout: "", stderr: "")
      status = instance_double(Process::Status, success?: success, exitstatus: success ? 0 : 1)
      allow(Open3).to receive(:capture3) do |*command|
        @captured_command = command
        [ stdout, stderr, status ]
      end
    end

    context "when the book_file is a pdf" do
      let(:source) { create(:book_file, :on_disk, format: "pdf") }

      it "shells out to pdftotext with the expected flags and returns stdout" do
        stub_pdftotext(success: true, stdout: "extracted pdf text")

        text = described_class.extract_text(source)

        expect(text).to eq("extracted pdf text")
        expect(@captured_command).to eq(
          [ "timeout", "--signal=KILL", Library::TextCompanion::DEFAULT_TIMEOUT.to_s,
            "pdftotext", "-enc", "UTF-8", "-nopgbrk", source.read_source_path.to_s, "-" ]
        )
      end

      it "raises Library::TextCompanion::Error with the tail of stderr on a nonzero exit" do
        stub_pdftotext(success: false, stderr: "x" * 5000 + "the real reason it failed")

        expect {
          described_class.extract_text(source)
        }.to raise_error(described_class::Error, /the real reason it failed/)
      end

      it "falls back to stdout when stderr is blank" do
        stub_pdftotext(success: false, stdout: "stdout failure detail", stderr: "")

        expect {
          described_class.extract_text(source)
        }.to raise_error(described_class::Error, /stdout failure detail/)
      end

      it "reads from the OCR companion via #read_source_path when one is fresh" do
        FileUtils.mkdir_p(Library.base_root.join("ocr"))
        ocr_path = "ocr/#{source.book.public_id}.ocr.pdf"
        File.write(Library.base_root.join(ocr_path), "ocr'd pdf bytes")
        source.update!(ocr_path: ocr_path, ocr_sha256: "ocr-sha", ocr_source_sha256: source.sha256)
        stub_pdftotext(success: true, stdout: "text")

        described_class.extract_text(source)

        expect(@captured_command.last(2)).to eq([ source.ocr_absolute_path.to_s, "-" ])
      end

      it "scrubs invalid UTF-8 byte sequences from pdftotext's output" do
        stub_pdftotext(success: true, stdout: "hello \xFF\xFE world".dup.force_encoding("UTF-8"))

        text = described_class.extract_text(source)

        expect(text.valid_encoding?).to be(true)
      end
    end

    context "when the book_file is not a pdf" do
      let(:source) { create(:book_file, :on_disk, format: "epub") }

      it "falls back to Calibre.extract_text and never shells out to pdftotext" do
        allow(Calibre).to receive(:extract_text).with(source.read_source_path).and_return("calibre text")
        expect(Open3).not_to receive(:capture3)

        text = described_class.extract_text(source)

        expect(text).to eq("calibre text")
      end
    end
  end
end
