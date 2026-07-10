require 'rails_helper'

RSpec.describe Library::Opf do
  let(:opf_xml) do
    <<~XML
      <?xml version='1.0' encoding='utf-8'?>
      <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uuid_id" version="2.0">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
          <dc:title>The Hollow Hills</dc:title>
          <dc:creator opf:file-as="Stewart, Mary" opf:role="aut">Mary Stewart</dc:creator>
          <dc:description>&lt;p&gt;Second book of the &lt;i&gt;Merlin&lt;/i&gt; trilogy.&lt;/p&gt;</dc:description>
          <dc:date>1973-06-01T00:00:00+00:00</dc:date>
          <dc:language>eng</dc:language>
          <meta content="Arthurian Saga" name="calibre:series"/>
          <meta content="2.0" name="calibre:series_index"/>
        </metadata>
      </package>
    XML
  end

  it "parses the Book-relevant subset of a Calibre metadata.opf" do
    file = Rails.root.join("tmp", "opf-spec.opf")
    File.write(file, opf_xml)

    meta = described_class.parse(file)

    expect(meta[:title]).to eq("The Hollow Hills")
    expect(meta[:author]).to eq("Mary Stewart")
    expect(meta[:series]).to eq("Arthurian Saga")
    expect(meta[:series_index]).to eq(2.0)
    expect(meta[:language]).to eq("eng")
    expect(meta[:description]).to include("Merlin trilogy")
    expect(meta[:description]).not_to include("<p>")
    expect(meta[:published_year]).to eq(1973)
  ensure
    FileUtils.rm_f(file)
  end

  it "returns an empty hash for unreadable or invalid files" do
    expect(described_class.parse("/nonexistent/metadata.opf")).to eq({})
  end
end
