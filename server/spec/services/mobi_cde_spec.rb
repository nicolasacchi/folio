require 'rails_helper'

RSpec.describe Library::MobiCde do
  let(:path) { Rails.root.join("tmp", "test_storage", "mobi_cde", "book.azw3").to_s }

  it "extracts ASIN and cdeType from EXTH" do
    MobiFixture.write(path, exth: { 113 => "0a370608-e84b-425c-b72a", 501 => "EBOK" })

    expect(described_class.parse(path)).to eq(asin: "0a370608-e84b-425c-b72a", cde_type: "EBOK")
  end

  it "falls back to EXTH 504 when 113 is absent" do
    MobiFixture.write(path, exth: { 504 => "B00ASIN504", 501 => "PDOC" })

    expect(described_class.parse(path)).to eq(asin: "B00ASIN504", cde_type: "PDOC")
  end

  it "returns nils when the file has no EXTH identity" do
    MobiFixture.write(path, exth: { 100 => "An Author" })

    expect(described_class.parse(path)).to eq(asin: nil, cde_type: nil)
  end

  it "returns nils for a missing file" do
    expect(described_class.parse("/nonexistent/book.azw3")).to eq(asin: nil, cde_type: nil)
  end

  it "returns nils for a non-MOBI file" do
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, "%PDF-1.4 not a palm database at all" * 10)

    expect(described_class.parse(path)).to eq(asin: nil, cde_type: nil)
  end
end
