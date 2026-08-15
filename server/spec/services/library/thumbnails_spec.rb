require 'rails_helper'

RSpec.describe Library::Thumbnails do
  # Stubbed so this spec never touches the real (shared, suite-wide)
  # LIBRARY_ROOT test storage directory.
  let(:root) { Pathname.new(Dir.mktmpdir("thumbnails-spec")) }

  before { allow(Library).to receive(:base_root).and_return(root) }
  after { FileUtils.rm_rf(root) }

  # Hand-rolled 4x4 RGB PNG (raw scanlines, zlib-deflated) so the spec has
  # a real, decodable cover to feed libvips — no binary fixture file, no
  # dependency on vips to build its own input.
  def write_cover(book)
    width = height = 4
    raw = Array.new(height) { "\x00" + ("\xAA\xBB\xCC" * width) }.join
    ihdr = [ width, height, 8, 2, 0, 0, 0 ].pack("NNCCCCC")
    chunk = lambda do |type, data|
      [ data.bytesize ].pack("N") + type + data + [ Zlib.crc32(type + data) ].pack("N")
    end

    png = "\x89PNG\r\n\x1a\n".b
    png << chunk.call("IHDR", ihdr)
    png << chunk.call("IDAT", Zlib::Deflate.deflate(raw))
    png << chunk.call("IEND", "")

    FileUtils.mkdir_p(File.dirname(Library.cover_path(book)))
    File.binwrite(Library.cover_path(book), png)
  end

  # Regression coverage for the image_processing 2.x bump: that release made
  # ruby-vips a soft dependency, and Thumbnails.ensure rescues
  # LoadError/StandardError broadly — without asserting real output, a
  # missing ruby-vips gem would silently no-op instead of failing loudly.
  it "renders a real JPEG thumbnail from the book's cover" do
    book = create(:book)
    write_cover(book)

    thumb = described_class.ensure(book)

    expect(thumb).to eq(Library::Thumbnails.path(book))
    expect(File).to exist(thumb)

    data = File.binread(thumb)
    expect(data.byteslice(0, 3).bytes).to eq([ 0xFF, 0xD8, 0xFF ]) # JPEG magic
    expect(data.bytesize).to be > 0
  end

  it "logs and returns nil instead of raising when the cover can't be decoded" do
    book = create(:book)
    FileUtils.mkdir_p(File.dirname(Library.cover_path(book)))
    File.binwrite(Library.cover_path(book), "not an image")

    expect(Rails.logger).to receive(:warn).with(/thumbnail generation failed/)
    expect(described_class.ensure(book)).to be_nil
  end

  it "returns nil without a cover" do
    book = create(:book)

    expect(described_class.ensure(book)).to be_nil
  end
end
