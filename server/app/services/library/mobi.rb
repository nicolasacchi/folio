# Minimal MOBI header reading. Sidecar positions are offsets into the
# book's uncompressed text, so percent estimates need the PalmDOC
# text_length, not the file size (which includes markup, images and
# indexes — off by 2x on a typical book).
module Library::Mobi
  # Raised for anything raw_text can't handle: HUFF/CDIC-compressed
  # (dictionary) text, or a file that doesn't parse as a PalmDB/MOBI
  # container. Deliberately narrow — callers should treat this as "no
  # text available", not retry.
  class Unsupported < StandardError; end

  COMPRESSION_NONE = 1
  COMPRESSION_PALMDOC = 2
  COMPRESSION_HUFF = 17480

  # Byte offset of the MOBI header's "Extra Flags" u16 field, relative
  # to the "MOBI" identifier (i.e. the start of the MOBI header itself,
  # which sits right after the 16-byte PalmDOC header in record 0).
  # Widely documented at 0xF2 across MOBI format references; only
  # trustworthy when the header reports itself long enough to include
  # it (older/minimal headers omit it — treated as "no extra flags").
  EXTRA_FLAGS_OFFSET = 0xF2

  module_function

  # Uncompressed text length from the PalmDOC header in record 0, or nil
  # when the file isn't a MOBI/AZW.
  def text_length(path)
    File.open(path, "rb") do |file|
      header = file.read(82).to_s.b
      return nil unless header.byteslice(60, 8) == "BOOKMOBI"

      record0 = header.byteslice(78, 4)&.unpack1("N")
      return nil unless record0

      file.seek(record0 + 4)
      length = file.read(4).to_s.b
      length.bytesize == 4 ? length.unpack1("N") : nil
    end
  rescue SystemCallError
    nil
  end

  # Full uncompressed text stream of the MOBI6 half of the file (for a
  # joint MOBI6+KF8 file, record 0 is still the MOBI6 header, and its
  # own record_count only spans its own text records — the KF8 half
  # never gets touched). Returns a BINARY-encoded String.
  def raw_text(path)
    bytes = File.binread(path).to_s.b
    offsets = record_offsets(bytes)
    raise Unsupported, "not a PalmDB file" if offsets.empty?

    record0 = record_bytes(bytes, offsets, 0)
    raise Unsupported, "missing record 0" unless record0
    raise Unsupported, "not a MOBI file" unless record0.byteslice(16, 4) == "MOBI"

    compression = record0.byteslice(0, 2)&.unpack1("n")
    text_length = record0.byteslice(4, 4)&.unpack1("N")
    text_record_count = record0.byteslice(8, 2)&.unpack1("n")
    raise Unsupported, "HUFF/CDIC compression is unsupported" if compression == COMPRESSION_HUFF
    unless [ COMPRESSION_NONE, COMPRESSION_PALMDOC ].include?(compression)
      raise Unsupported, "unknown PalmDOC compression #{compression.inspect}"
    end

    flags = extra_flags(record0)
    out = +"".b
    (1..text_record_count.to_i).each do |index|
      record = record_bytes(bytes, offsets, index)
      break unless record

      payload = strip_trailing_entries(record, flags)
      out << (compression == COMPRESSION_PALMDOC ? Library::PalmDoc.decompress(payload) : payload)
    end

    out.byteslice(0, text_length || out.bytesize).to_s
  end

  # -- PalmDB record layout --------------------------------------------

  # Byte offset of each record, read from the standard 78-byte PalmDB
  # header (record count at offset 76) + 8-byte-per-record directory.
  def record_offsets(bytes)
    count = bytes.byteslice(76, 2)&.unpack1("n")
    return [] unless count&.positive?

    offsets = Array.new(count) { |i| bytes.byteslice(78 + i * 8, 4)&.unpack1("N") }
    offsets.any?(&:nil?) ? [] : offsets
  end

  def record_bytes(bytes, offsets, index)
    start = offsets[index]
    return nil unless start

    stop = offsets[index + 1] || bytes.bytesize
    bytes.byteslice(start, stop - start)
  end

  # -- MOBI header extra flags / trailing entries -----------------------

  def extra_flags(record0)
    header_length = record0.byteslice(20, 4)&.unpack1("N")
    return 0 unless header_length && header_length >= EXTRA_FLAGS_OFFSET + 2

    record0.byteslice(16 + EXTRA_FLAGS_OFFSET, 2)&.unpack1("n") || 0
  end

  # Strips the variable-length trailing data (multibyte-char
  # continuation bytes and/or indexing metadata) MOBI appends after
  # each text record's compressed/raw payload, per the extra-flags
  # bitfield. Algorithm per the MOBI format notes: each set bit above
  # bit 0 marks one more trailing entry, self-describing its own byte
  # length via a backward variable-width integer; bit 0 (checked last,
  # against what's left after the others are stripped) marks a final
  # multibyte-trailing chunk whose length is just the low 2 bits of
  # the new last byte, +1.
  #
  # `stripped` is clamped to record.bytesize (and the loop stops once it's
  # reached) because a corrupt/truncated record can hand back a decoded vint
  # bigger than what's actually left — e.g. a single trailing byte with the
  # high bit set decodes to 127 on its own, regardless of the record's real
  # size. Without the clamp, the final byteslice's length goes negative,
  # which returns nil (not "the whole record" or an error) and crashes the
  # caller. A clamped record is not a *correct* decode, but it's a bounded,
  # non-crashing best effort, consistent with this module's #raw_text
  # otherwise degrading via Unsupported rather than raising.
  def strip_trailing_entries(record, flags)
    return record if flags.zero?

    stripped = 0
    remaining_flags = flags >> 1
    while remaining_flags.positive? && stripped < record.bytesize
      stripped += trailing_entry_size(record, record.bytesize - stripped) if remaining_flags.odd?
      remaining_flags >>= 1
    end
    stripped = record.bytesize if stripped > record.bytesize

    if flags.odd? && record.bytesize > stripped
      stripped += (record.getbyte(record.bytesize - stripped - 1) & 0x3) + 1
      stripped = record.bytesize if stripped > record.bytesize
    end

    record.byteslice(0, record.bytesize - stripped)
  end

  # Backward variable-width integer: read bytes from the end of
  # `record[0, size]`, low 7 bits per byte, most-significant byte
  # last (i.e. first one hit going backward is least-significant);
  # a set high bit marks that byte as the final (most-significant)
  # one. The decoded value is the trailing entry's *total* on-disk
  # size, including the vint bytes themselves.
  def trailing_entry_size(record, size)
    result = 0
    bit_offset = 0
    consumed = 0

    loop do
      byte = record.getbyte(size - consumed - 1)
      break if byte.nil?

      result |= (byte & 0x7F) << bit_offset
      bit_offset += 7
      consumed += 1
      break if byte & 0x80 != 0 || bit_offset >= 28 || consumed >= size
    end

    result
  end
end
