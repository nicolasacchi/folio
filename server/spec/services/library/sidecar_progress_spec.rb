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

  describe "KRDS sidecars (KPP firmware)" do
    # Real files written by a Kindle on firmware 5.19.2 at ~67% of a small
    # MOBI: fpr 31740 / lpr 31739 live in the .mbs, the .mbp1 only carries
    # flags and an empty annotation cache.
    let(:mbp1) { File.binread(Rails.root.join("spec/fixtures/sidecars/krds.mbp1")) }
    let(:mbs) { File.binread(Rails.root.join("spec/fixtures/sidecars/krds.mbs")) }

    it "takes the furthest position across KRDS members" do
      bundle = build_bundle("book.sdr/book.mbp1" => mbp1, "book.sdr/book.mbs" => mbs)
      result = described_class.parse(bundle)

      expect(result.source).to eq("krds")
      expect(result.last_position).to eq(31_740)
      expect(result.annotation_count).to eq(0)
      expect(result.files).to contain_exactly("book.mbp1", "book.mbs")
    end

    it "counts cached personal annotations" do
      annotated = mbp1 + "annotation.personal.bookmark".b + "annotation.personal.highlight".b
      bundle = build_bundle("book.sdr/book.mbp1" => annotated)
      result = described_class.parse(bundle)

      expect(result.source).to eq("krds")
      expect(result.annotation_count).to eq(2)
    end
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
