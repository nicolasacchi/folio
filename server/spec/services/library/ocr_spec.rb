require 'rails_helper'

RSpec.describe Library::Ocr do
  describe ".language_for" do
    it "maps ISO 639-2/T codes to themselves, appending +eng" do
      expect(described_class.language_for(build(:book, language: "ita"))).to eq("ita+eng")
      expect(described_class.language_for(build(:book, language: "deu"))).to eq("deu+eng")
      expect(described_class.language_for(build(:book, language: "fra"))).to eq("fra+eng")
      expect(described_class.language_for(build(:book, language: "spa"))).to eq("spa+eng")
      expect(described_class.language_for(build(:book, language: "rus"))).to eq("rus+eng")
      expect(described_class.language_for(build(:book, language: "por"))).to eq("por+eng")
      expect(described_class.language_for(build(:book, language: "ara"))).to eq("ara+eng")
    end

    it "maps bare ISO 639-1 codes the same way" do
      expect(described_class.language_for(build(:book, language: "it"))).to eq("ita+eng")
      expect(described_class.language_for(build(:book, language: "es"))).to eq("spa+eng")
      expect(described_class.language_for(build(:book, language: "de"))).to eq("deu+eng")
    end

    it "does not double up +eng when the book is already English" do
      expect(described_class.language_for(build(:book, language: "eng"))).to eq("eng")
      expect(described_class.language_for(build(:book, language: "en"))).to eq("eng")
    end

    it "is case-insensitive" do
      expect(described_class.language_for(build(:book, language: "ITA"))).to eq("ita+eng")
    end

    it "falls back to Italian-dominant default for blank or unrecognized languages" do
      expect(described_class.language_for(build(:book, language: nil))).to eq("ita+eng")
      expect(described_class.language_for(build(:book, language: ""))).to eq("ita+eng")
      expect(described_class.language_for(build(:book, language: "xx-garbage"))).to eq("ita+eng")
    end
  end

  describe ".call" do
    let(:source) { Rails.root.join("tmp", "ocr-spec-source-#{SecureRandom.hex(4)}.pdf") }
    let(:output) { Rails.root.join("tmp", "ocr-spec-output-#{SecureRandom.hex(4)}.pdf") }

    before { File.write(source, "not a real pdf, just needs to exist") }
    after { FileUtils.rm_f([ source, output, "#{output}.sidecar.txt" ]) }

    def stub_ocrmypdf(success:, stdout: "", stderr: "")
      status = instance_double(Process::Status, success?: success, exitstatus: success ? 0 : 1)
      allow(Open3).to receive(:capture3) do |*command|
        @captured_command = command
        # ocrmypdf itself isn't invoked (stubbed) — write the sidecar the
        # real binary would have produced so .call can read it back.
        sidecar_index = command.index("--sidecar")
        File.write(command[sidecar_index + 1], "  recognized text  \n") if sidecar_index && success
        [ stdout, stderr, status ]
      end
    end

    it "shells out with the expected ocrmypdf flags and returns the stripped sidecar text" do
      stub_ocrmypdf(success: true)

      text = described_class.call(source, output, language: "ita+eng", timeout: 60)

      expect(text).to eq("recognized text")
      expect(@captured_command).to include("ocrmypdf", "--skip-text", "--output-type", "pdf")
      expect(@captured_command.each_cons(2).to_a).to include(
        [ "-l", "ita+eng" ], [ "--jobs", "1" ], [ "--optimize", "1" ]
      )
      expect(@captured_command.last(2)).to eq([ source.to_s, output.to_s ])
    end

    it "cleans up the sidecar file after a successful run" do
      stub_ocrmypdf(success: true)

      described_class.call(source, output, language: "eng", timeout: 60)

      expect(File.exist?("#{output}.sidecar.txt")).to be(false)
    end

    it "raises Library::Ocr::Error with the tail of stderr on a nonzero exit" do
      stub_ocrmypdf(success: false, stderr: "x" * 5000 + "the real reason it failed")

      expect {
        described_class.call(source, output, language: "eng", timeout: 60)
      }.to raise_error(described_class::Error, /the real reason it failed/)
    end

    it "falls back to stdout when stderr is blank" do
      stub_ocrmypdf(success: false, stdout: "stdout failure detail", stderr: "")

      expect {
        described_class.call(source, output, language: "eng", timeout: 60)
      }.to raise_error(described_class::Error, /stdout failure detail/)
    end
  end
end
