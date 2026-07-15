require "rails_helper"

RSpec.describe Library::PalmDoc do
  describe ".decompress" do
    it "passes uncompressed (literal-only) bytes through unchanged" do
      expect(described_class.decompress("Hello, world!".b)).to eq("Hello, world!".b)
    end

    it "expands a 0x01-0x08 literal-run control byte" do
      # 0x03 says "copy the next 3 raw bytes literally"
      compressed = "\x03abcXYZ".b
      expect(described_class.decompress(compressed)).to eq("abcXYZ".b)
    end

    it "expands a 0xC0-0xFF space+char pair" do
      # 0xC1 -> ' ' + (0xC1 ^ 0x80) = ' ' + 0x41 = " A"
      compressed = "\x00\xC1B".b
      expect(described_class.decompress(compressed)).to eq("\x00 AB".b)
    end

    it "expands an overlapping distance/length back-reference (classic LZ77 run trick)" do
      # literal "A", then distance=1 length=5 -> repeats the last byte
      # 5 more times: "A" + "AAAAA" = "AAAAAA"
      combined = (1 << 3) | (5 - 3)
      back_ref = [ 0x80 | (combined >> 8), combined & 0xFF ].pack("CC")
      compressed = "A".b + back_ref

      expect(described_class.decompress(compressed)).to eq("AAAAAA".b)
    end

    it "round-trips a hand-built compressed sample mixing every control byte type" do
      # "\x00" literal null, "abc" via a literal run, " A" via space+char,
      # then "A" repeated via a back-reference, then a final plain literal.
      combined = (1 << 3) | (4 - 3) # distance=1, length=4
      back_ref = [ 0x80 | (combined >> 8), combined & 0xFF ].pack("CC")
      compressed = "\x00".b + "\x03abc".b + "\xC1".b + "A".b + back_ref + "!".b

      expect(described_class.decompress(compressed)).to eq("\x00abc AAAAAA!".b)
    end

    def back_ref(distance, length)
      combined = (distance << 3) | (length - 3)
      [ 0x80 | (combined >> 8), combined & 0xFF ].pack("CC")
    end

    it "stops decoding (without crashing) on a zero-distance back-reference" do
      # distance=0, length=5 -- can't come from a real PalmDOC encoder (there's
      # nothing to copy from at all); used to call out.getbyte(out.bytesize),
      # which is out of range (nil), and out << nil raised a TypeError.
      compressed = back_ref(0, 5)

      expect { described_class.decompress(compressed) }.not_to raise_error
      expect(described_class.decompress(compressed)).to eq("".b)
    end

    it "stops decoding (without crashing) on a back-reference distance beyond what's been decompressed so far" do
      # Only 1 byte ("A") has been decompressed when this back-reference
      # asks to copy from 5 bytes back -- corrupt/truncated input only.
      compressed = "A".b + back_ref(5, 3)

      expect { described_class.decompress(compressed) }.not_to raise_error
      expect(described_class.decompress(compressed)).to eq("A".b)
    end

    it "stops decoding (without crashing) on a back-reference control byte with no second byte" do
      # A truncated stream that cuts off right after a 0x80-0xBF control
      # byte, before its required second byte.
      compressed = "A".b + "\x80".b

      expect { described_class.decompress(compressed) }.not_to raise_error
      expect(described_class.decompress(compressed)).to eq("A".b)
    end
  end
end
