# PalmDOC/LZ77 decompression — the compression scheme MOBI6 text
# records use (PalmDOC header `compression == 2`). One byte at a time:
#
#   0x00      literal 0x00
#   0x01-0x08 the following N raw bytes are literal (copy verbatim)
#   0x09-0x7F literal ASCII byte
#   0x80-0xBF distance/length back-reference: this byte + the next
#             encode a 14-bit value; top 11 bits are the backward
#             distance (in already-decompressed output), low 3 bits
#             + 3 are the copy length (3-10 bytes). Distance/length
#             ranges can overlap the bytes being written (classic
#             LZ77 run-length trick), so copying is byte-by-byte.
#   0xC0-0xFF a space followed by (byte ^ 0x80) as a literal char
module Library
  module PalmDoc
    module_function

    def decompress(bytes)
      bytes = bytes.to_s.b
      out = +"".b
      i = 0
      size = bytes.bytesize

      while i < size
        byte = bytes.getbyte(i)
        i += 1

        case byte
        when 0x00
          out << 0x00
        when 0x01..0x08
          out << bytes.byteslice(i, byte)
          i += byte
        when 0x09..0x7F
          out << byte
        when 0x80..0xBF
          byte2 = bytes.getbyte(i)
          i += 1
          # A truncated stream (control byte with nothing after it) or a
          # back-reference distance that doesn't fit within what's actually
          # been decompressed so far (0, or beyond the start of `out`) can't
          # come from a well-formed PalmDOC encoder — only from a corrupt or
          # adversarial record. Rather than let `out.getbyte(...)` resolve to
          # nil and crash `out <<` with a TypeError, stop decoding here and
          # return whatever's been decompressed so far, same as any other
          # truncated-record case.
          break if byte2.nil?

          combined = ((byte & 0x3F) << 8) | byte2
          distance = combined >> 3
          length = (combined & 0x07) + 3
          break if distance.zero? || distance > out.bytesize

          length.times { out << out.getbyte(out.bytesize - distance) }
        when 0xC0..0xFF
          out << 0x20 << (byte ^ 0x80)
        end
      end

      out
    end
  end
end
