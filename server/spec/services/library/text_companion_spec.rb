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

  describe ".deep_ocr_text" do
    let(:source) { create(:book_file, :on_disk, format: "pdf") }
    let(:ok) { instance_double(Process::Status, success?: true, exitstatus: 0) }

    # command[3] is the actual program name (index 0-2 are the
    # timeout/--signal=KILL/timeout-seconds wrapper) — distinguishing on it
    # lets one stub answer both the pdftoppm and tesseract legs the way the
    # real two-phase call does. pdftoppm's stub has to actually create the
    # page files: #deep_ocr_text globs the tmpdir for what pdftoppm wrote,
    # it doesn't trust a page count.
    def stub_shell(pages: { "page-1.png" => "first page" }, raster_status: ok, page_status: ok, page_statuses: {}, raster_stderr: "", page_stderr: "")
      allow(Open3).to receive(:capture3) do |*command|
        if command[3] == "pdftoppm"
          @raster_command = command
          tmpdir = File.dirname(command.last)
          pages.each_key { |name| FileUtils.touch(File.join(tmpdir, name)) } if raster_status.success?
          [ "", raster_stderr, raster_status ]
        elsif command[3] == "tesseract"
          @tesseract_commands ||= []
          @tesseract_commands << command
          png_name = File.basename(command[4])
          [ pages.fetch(png_name, ""), page_stderr, page_statuses.fetch(png_name, page_status) ]
        else
          raise "unexpected command: #{command.inspect}"
        end
      end
    end

    it "rasterizes the raw pdf (never #read_source_path) at 300dpi grayscale via pdftoppm" do
      ocr_path = "ocr/#{source.book.public_id}.ocr.pdf"
      FileUtils.mkdir_p(Library.base_root.join(ocr_path).dirname)
      File.write(Library.base_root.join(ocr_path), "ocr'd pdf bytes")
      source.update!(ocr_path: ocr_path, ocr_sha256: "ocr-sha", ocr_source_sha256: source.sha256)
      stub_shell

      described_class.deep_ocr_text(source)

      expect(@raster_command).to eq(
        [ "timeout", "--signal=KILL", Library::TextCompanion::DEEP_RASTER_TIMEOUT.to_s,
          "pdftoppm", "-r", "300", "-gray", "-png", source.absolute_path.to_s, @raster_command.last ]
      )
      expect(source.absolute_path).not_to eq(source.read_source_path) # sanity: the OCR companion really is preferred elsewhere
    end

    it "OCRs each rasterized page with tesseract, in sorted order, joining with a blank line" do
      stub_shell(pages: { "page-1.png" => "first page", "page-2.png" => "second page" })

      text = described_class.deep_ocr_text(source)

      expect(text).to eq("first page\n\nsecond page")
      expect(@tesseract_commands.map { |c| File.basename(c[4]) }).to eq(%w[page-1.png page-2.png])
    end

    it "passes -l/--psm matching Library::Ocr's default language and full-auto page segmentation" do
      stub_shell
      described_class.deep_ocr_text(source)

      expect(@tesseract_commands.first).to eq(
        [ "timeout", "--signal=KILL", Library::TextCompanion::DEEP_PAGE_TIMEOUT.to_s,
          "tesseract", @tesseract_commands.first[4], "stdout", "-l", Library::Ocr::DEFAULT_LANGUAGE, "--psm", "3" ]
      )
    end

    it "raises with the tail of stderr when pdftoppm fails" do
      failed = instance_double(Process::Status, success?: false, exitstatus: 1)
      stub_shell(raster_status: failed, raster_stderr: "raster blew up")

      expect { described_class.deep_ocr_text(source) }.to raise_error(described_class::Error, /raster blew up/)
    end

    it "raises when pdftoppm produces no page images" do
      stub_shell(pages: {})

      expect { described_class.deep_ocr_text(source) }.to raise_error(described_class::Error, /no page images/)
    end

    it "raises naming the page when tesseract fails on it" do
      failed = instance_double(Process::Status, success?: false, exitstatus: 1)
      stub_shell(pages: { "page-1.png" => "" }, page_status: failed, page_stderr: "tesseract choked")

      expect { described_class.deep_ocr_text(source) }.to raise_error(described_class::Error, /page-1\.png.*tesseract choked/m)
    end

    it "keeps every other page's text when a single page's tesseract fails" do
      failed = instance_double(Process::Status, success?: false, exitstatus: 137)
      stub_shell(
        pages: { "page-1.png" => "first page", "page-2.png" => "second page", "page-3.png" => "third page" },
        page_statuses: { "page-2.png" => failed },
        page_stderr: "wedged"
      )

      expect(described_class.deep_ocr_text(source)).to eq("first page\n\nthird page")
    end

    it "uses the book's own language for tesseract when it has one" do
      source.book.update!(language: "es")
      stub_shell

      described_class.deep_ocr_text(source)

      expect(@tesseract_commands.first[6..7]).to eq([ "-l", "spa+eng" ])
    end

    it "scrubs invalid UTF-8 byte sequences from the joined page text" do
      stub_shell(pages: { "page-1.png" => "hello \xFF\xFE world".dup.force_encoding("UTF-8") })

      text = described_class.deep_ocr_text(source)

      expect(text.valid_encoding?).to be(true)
    end

    it "cleans up its temp directory even after a failure" do
      failed = instance_double(Process::Status, success?: false, exitstatus: 1)
      stub_shell(raster_status: failed)
      captured_tmpdir = nil
      allow(Dir).to receive(:mktmpdir).and_wrap_original do |original, *args, &block|
        original.call(*args) { |dir| captured_tmpdir = dir; block.call(dir) }
      end

      expect { described_class.deep_ocr_text(source) }.to raise_error(described_class::Error)
      expect(captured_tmpdir).to be_present
      expect(Dir.exist?(captured_tmpdir)).to be(false)
    end
  end
end
