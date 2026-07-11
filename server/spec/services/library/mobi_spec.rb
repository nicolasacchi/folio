require 'rails_helper'

RSpec.describe Library::Mobi do
  def build_mobi(text_length:)
    header = "\x00".b * 60
    header << "BOOKMOBI".b            # type/creator at offset 60
    header << "\x00".b * 8            # up to num_records at 76
    header << [ 1 ].pack("n")         # one record
    record0_offset = 86
    header << [ record0_offset ].pack("N")
    header << "\x00".b * (record0_offset - header.bytesize)
    header << [ 1 ].pack("n") << "\x00\x00".b << [ text_length ].pack("N")
    header
  end

  it "reads the PalmDOC uncompressed text length" do
    path = Rails.root.join("tmp", "mobi-#{SecureRandom.hex(4)}.mobi")
    File.binwrite(path, build_mobi(text_length: 46_738))

    expect(described_class.text_length(path)).to eq(46_738)
  ensure
    FileUtils.rm_f(path)
  end

  it "is nil for non-MOBI files" do
    path = Rails.root.join("tmp", "mobi-#{SecureRandom.hex(4)}.epub")
    File.binwrite(path, "PK\x03\x04 not a mobi")

    expect(described_class.text_length(path)).to be_nil
  ensure
    FileUtils.rm_f(path)
  end

  it "is nil for a missing file" do
    expect(described_class.text_length(Rails.root.join("tmp/nope.mobi"))).to be_nil
  end
end
