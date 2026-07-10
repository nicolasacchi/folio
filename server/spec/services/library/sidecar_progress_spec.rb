require 'rails_helper'
require 'rubygems/package'

RSpec.describe Library::SidecarProgress do
  def build_bundle(files)
    path = Rails.root.join("tmp", "sidecar-#{SecureRandom.hex(4)}.tar.gz")
    File.open(path, "wb") do |io|
      Zlib::GzipWriter.wrap(io) do |gz|
        Gem::Package::TarWriter.new(gz) do |tar|
          files.each do |name, bytes|
            tar.add_file_simple(name, 0o644, bytes.bytesize) { |entry| entry.write(bytes) }
          end
        end
      end
    end
    path
  end

  after { Dir.glob(Rails.root.join("tmp", "sidecar-*.tar.gz")) { |f| FileUtils.rm_f(f) } }

  it "extracts position and bookmark count from an MBP sidecar" do
    mbp = +"BPARMOBI".b
    mbp << "\x00" * 8
    mbp << "DATA".b << [ 123_456 ].pack("N")
    mbp << "BKMK".b << "\x00" * 4 << "BKMK".b

    bundle = build_bundle("book.sdr/book.mbp1" => mbp, "book.sdr/book.mbs" => "x".b)
    result = described_class.parse(bundle)

    expect(result.source).to eq("mbp")
    expect(result.last_position).to eq(123_456)
    expect(result.annotation_count).to eq(2)
    expect(result.files).to contain_exactly("book.mbp1", "book.mbs")
  end

  it "degrades to an inventory when the sidecar format is unknown" do
    bundle = build_bundle("book.sdr/book.azw3r" => "\x00\x01krds-ish".b)
    result = described_class.parse(bundle)

    expect(result.source).to eq("none")
    expect(result.last_position).to be_nil
    expect(result.files).to eq([ "book.azw3r" ])
  end

  it "returns an unreadable result for garbage input" do
    path = Rails.root.join("tmp", "sidecar-garbage.tar.gz")
    File.binwrite(path, "not a tarball")

    expect(described_class.parse(path).source).to eq("unreadable")
  ensure
    FileUtils.rm_f(path)
  end
end
