require 'rails_helper'

RSpec.describe Library::KindlePrep do
  let(:book) { create(:book) }
  let(:file) { create(:book_file, book: book, format: "azw3", sha256: "src-sha") }

  before do
    MobiFixture.write(file.absolute_path,
      exth: { 113 => "0a37-uuid", 112 => "calibre:0a37", 501 => "EBOK", 100 => "An Author" })
    allow(Calibre).to receive(:available?).and_return(false)
  end

  it "rewrites the store identity in the prepared copy" do
    described_class.prepare!(file)
    file.reload

    expect(file.prepared_path).to be_present
    expect(file.prepared_source_sha256).to eq("src-sha")
    expect(file.prepared_sha256).to eq(Library.sha256(file.prepared_absolute_path))
    expect(file.prepared_size).to eq(File.size(file.prepared_absolute_path))

    # No ASIN left, and the cdeType says personal document — the scanner
    # leaves AZW3 rows typeless without one, which the Library UI renders
    # as a cover-less text tile.
    identity = Library::MobiCde.parse(file.prepared_absolute_path)
    expect(identity).to eq(asin: nil, cde_type: "PDOC")
    expect(file.asin).to be_nil
    expect(file.cde_type).to eq("PDOC")

    # Non-identity records survive untouched.
    records = Library::MobiCde.exth_records(file.prepared_absolute_path)
    expect(records[100]).to eq("An Author")
    # The neutralized ASIN records are still present, under unknown type ids.
    expect(records[113 + 6000]).to eq("0a37-uuid")
    expect(records[112 + 6000]).to eq("calibre:0a37")
  end

  it "neutralizes an odd-length cdeType instead of rewriting it" do
    MobiFixture.write(file.absolute_path, exth: { 501 => "MAGZ!" })
    described_class.prepare!(file)

    records = Library::MobiCde.exth_records(file.prepared_absolute_path)
    expect(records[501]).to be_nil
    expect(records[501 + 6000]).to eq("MAGZ!")
  end

  it "leaves the source file untouched" do
    original = File.binread(file.absolute_path)
    described_class.prepare!(file)
    expect(File.binread(file.absolute_path)).to eq(original)
  end

  it "makes delivery helpers point at the prepared copy" do
    described_class.prepare!(file)
    file.reload

    expect(file).to be_prepared_fresh
    expect(file).not_to be_needs_preparation
    expect(file.delivery_path).to eq(file.prepared_absolute_path)
    expect(file.delivery_sha256).to eq(file.prepared_sha256)
  end

  it "detects staleness when the source changes" do
    described_class.prepare!(file)
    file.reload
    file.update!(sha256: "new-sha")

    expect(file).not_to be_prepared_fresh
    expect(file).to be_needs_preparation
    expect(file.delivery_sha256).to eq("new-sha")
  end

  it "declines non-mobi formats" do
    pdf = create(:book_file, book: create(:book), format: "pdf")
    expect(described_class.prepare!(pdf)).to be_nil
    expect(pdf).not_to be_needs_preparation
  end

  it "copes with files that have no EXTH block" do
    File.binwrite(file.absolute_path, "not a mobi at all")
    file.update!(sha256: "raw")

    expect { described_class.prepare!(file) }.not_to raise_error
    expect(file.reload).to be_prepared_fresh
  end

  describe "azw3 → joint mobi transcode" do
    it "converts through calibre and delivers a .mobi" do
      allow(Calibre).to receive(:available?).and_return(true)
      allow(Calibre).to receive(:convert) do |_source, staging, options:|
        expect(options).to eq([ "--mobi-file-type", "both" ])
        MobiFixture.write(staging.to_s, exth: { 113 => "re-added-uuid", 501 => "EBOK" })
      end

      described_class.prepare!(file)
      file.reload

      expect(file.prepared_path).to end_with(".mobi")
      expect(file.delivery_format).to eq("mobi")
      expect(file.delivery_filename).to eq("#{File.basename(file.filename, '.*')}.mobi")
      # The transcode output still gets its identity rewritten.
      expect(Library::MobiCde.parse(file.prepared_absolute_path)).to eq(asin: nil, cde_type: "PDOC")
    end

    it "falls back to the byte-patched copy when the transcode fails" do
      allow(Calibre).to receive(:available?).and_return(true)
      allow(Calibre).to receive(:convert).and_raise(Calibre::Error, "boom")

      described_class.prepare!(file)
      file.reload

      expect(file.prepared_path).to end_with(".azw3")
      expect(file.delivery_filename).to end_with(".azw3")
      expect(Library::MobiCde.parse(file.prepared_absolute_path)).to eq(asin: nil, cde_type: "PDOC")
    end

    it "patches every MOBI header in a joint file" do
      path = Rails.root.join("tmp", "test_storage", "joint.mobi").to_s
      MobiFixture.write_joint(path, exth: { 113 => "uuid", 501 => "EBOK" })

      expect(described_class.neutralize_store_identity!(path)).to be(true)

      contents = File.binread(path)
      # Both EXTH copies rewritten: no live ASIN record, both cdeTypes PDOC.
      expect(contents.scan("PDOC").size).to eq(2)
      expect(contents.scan("EBOK")).to be_empty
      expect(Library::MobiCde.parse(path)).to eq(asin: nil, cde_type: "PDOC")
    end
  end
end
