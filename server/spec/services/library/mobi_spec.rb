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

  describe ".raw_text" do
    def tmp_path
      Rails.root.join("tmp", "mobi-rawtext-#{SecureRandom.hex(4)}.mobi")
    end

    # A single-byte 0x80/0xBF back-reference: distance/length packed
    # into 14 bits, top 2 bits fixed at 0b10.
    def back_ref(distance, length)
      combined = (distance << 3) | (length - 3)
      [ 0x80 | (combined >> 8), combined & 0xFF ].pack("CC")
    end

    it "extracts an uncompressed single-record text stream" do
      path = tmp_path
      text = "Hello, Kindle world!".b
      MobiFixture.write_with_text(path, compression: Library::Mobi::COMPRESSION_NONE,
        text_length: text.bytesize, text_records: [ text ])

      expect(described_class.raw_text(path)).to eq(text)
    ensure
      FileUtils.rm_f(path)
    end

    it "decompresses a PalmDOC-compressed single record" do
      path = tmp_path
      compressed = "A".b + back_ref(1, 5) # "A" + 5-back-reference => "AAAAAA"
      MobiFixture.write_with_text(path, compression: Library::Mobi::COMPRESSION_PALMDOC,
        text_length: 6, text_records: [ compressed ])

      expect(described_class.raw_text(path)).to eq("AAAAAA".b)
    ensure
      FileUtils.rm_f(path)
    end

    it "strips a single-byte trailing entry before returning the text" do
      path = tmp_path
      text = "Hello!".b
      record = text + MobiFixture.trailing_entry(1) # flags bit 1 => one numbered trailing entry
      MobiFixture.write_with_text(path, compression: Library::Mobi::COMPRESSION_NONE,
        text_length: text.bytesize, extra_flags: 0b10, text_records: [ record ])

      expect(described_class.raw_text(path)).to eq(text)
    ensure
      FileUtils.rm_f(path)
    end

    it "strips a multibyte-char trailing chunk (extra flags bit 0)" do
      path = tmp_path
      text = "Hi!".b
      # last byte's low 2 bits (+1) say how many trailing bytes to strip
      record = text + "XY\x02".b
      MobiFixture.write_with_text(path, compression: Library::Mobi::COMPRESSION_NONE,
        text_length: text.bytesize, extra_flags: 0b01, text_records: [ record ])

      expect(described_class.raw_text(path)).to eq(text)
    ensure
      FileUtils.rm_f(path)
    end

    it "strips a combined multibyte-chunk + numbered trailing entry, in the right order" do
      path = tmp_path
      text = "Hi!".b
      record = text + "XY\x02".b + MobiFixture.trailing_entry(1)
      MobiFixture.write_with_text(path, compression: Library::Mobi::COMPRESSION_NONE,
        text_length: text.bytesize, extra_flags: 0b11, text_records: [ record ])

      expect(described_class.raw_text(path)).to eq(text)
    ensure
      FileUtils.rm_f(path)
    end

    it "strips a trailing entry from a compressed record before decompressing it" do
      path = tmp_path
      compressed = "A".b + back_ref(1, 5) + MobiFixture.trailing_entry(1)
      MobiFixture.write_with_text(path, compression: Library::Mobi::COMPRESSION_PALMDOC,
        text_length: 6, extra_flags: 0b10, text_records: [ compressed ])

      expect(described_class.raw_text(path)).to eq("AAAAAA".b)
    ensure
      FileUtils.rm_f(path)
    end

    it "concatenates multiple text records and truncates to text_length" do
      path = tmp_path
      records = [ "Hello, ".b, "world!!!".b ] # concatenated + padding beyond text_length
      MobiFixture.write_with_text(path, compression: Library::Mobi::COMPRESSION_NONE,
        text_length: 13, text_records: records)

      expect(described_class.raw_text(path)).to eq("Hello, world!".b)
    ensure
      FileUtils.rm_f(path)
    end

    it "raises Unsupported for HUFF/CDIC-compressed text" do
      path = tmp_path
      MobiFixture.write_with_text(path, compression: Library::Mobi::COMPRESSION_HUFF,
        text_length: 10, text_records: [ "irrelevant".b ])

      expect { described_class.raw_text(path) }.to raise_error(Library::Mobi::Unsupported)
    ensure
      FileUtils.rm_f(path)
    end

    it "raises Unsupported for a file that isn't MOBI at all" do
      path = tmp_path
      File.binwrite(path, "PK\x03\x04 not a mobi".b)

      expect { described_class.raw_text(path) }.to raise_error(Library::Mobi::Unsupported)
    ensure
      FileUtils.rm_f(path)
    end

    it "does not crash when a trailing-entry vint overshoots the record's actual size" do
      path = tmp_path
      # A lone trailing byte with the high bit set decodes to 127 on its
      # own (MobiFixture.trailing_entry), far more than this 4-byte record
      # has room for. Regression for strip_trailing_entries returning a
      # negative-length byteslice (nil) and crashing raw_text.
      record = "abc".b + MobiFixture.trailing_entry(127)
      MobiFixture.write_with_text(path, compression: Library::Mobi::COMPRESSION_NONE,
        text_length: 10, extra_flags: 0b10, text_records: [ record ])

      expect { described_class.raw_text(path) }.not_to raise_error
      expect(described_class.raw_text(path)).to eq("".b)
    ensure
      FileUtils.rm_f(path)
    end
  end
end
