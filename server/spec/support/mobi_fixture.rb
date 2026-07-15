# Builds a minimal-but-valid PalmDB/MOBI byte string with the given EXTH
# records, enough for Library::MobiCde to parse (and representative of
# what calibre/ebook-convert emits).
module MobiFixture
  module_function

  # exth: { 113 => "uuid", 501 => "EBOK" }
  def build(exth: {})
    exth_records = exth.map { |type, value| [ type, value.bytesize + 8, value ].pack("NNa*") }.join
    exth_block = "EXTH" + [ exth_block_length(exth_records), exth.size ].pack("NN") + exth_records

    palmdoc_header = "\x00" * 16
    mobi_header_length = 24
    mobi_header = "MOBI" + [ mobi_header_length ].pack("N") + ("\x00" * (mobi_header_length - 8))
    record0 = palmdoc_header + mobi_header + exth_block
    record1 = "BOOKCONTENT"

    header = "spec-book".ljust(32, "\x00")            # db name
    header += [ 0, 0 ].pack("nn")                     # attributes, version
    header += [ 0, 0, 0 ].pack("NNN")                 # created, modified, backup
    header += [ 0, 0, 0 ].pack("NNN")                 # modnum, appinfo, sortinfo
    header += "BOOK" + "MOBI"                         # type, creator
    header += [ 0, 0 ].pack("NN")                     # uid seed, next record list
    header += [ 2 ].pack("n")                         # record count

    rec0_offset = header.bytesize + 2 * 8 + 2         # + record entries + 2-byte pad
    rec1_offset = rec0_offset + record0.bytesize
    entries = [ rec0_offset, 0, rec1_offset, 0 ].pack("NNNN")

    header + entries + "\x00\x00" + record0 + record1
  end

  def exth_block_length(records)
    12 + records.bytesize
  end

  # A joint MOBI6+KF8-style file: two MOBI-header records (each with its
  # own EXTH copy), like calibre's --mobi-file-type both output.
  def build_joint(exth: {})
    header_record = mobi_header_record(exth)
    records = [ header_record, "BOOKCONTENT", header_record.dup, "KF8CONTENT" ]

    header = "spec-joint".ljust(32, "\x00")
    header += [ 0, 0 ].pack("nn") + ([ 0 ] * 6).pack("N6")
    header += "BOOK" + "MOBI" + [ 0, 0 ].pack("NN")
    header += [ records.size ].pack("n")

    offset = header.bytesize + records.size * 8 + 2
    entries = +""
    records.each do |record|
      entries << [ offset, 0 ].pack("NN")
      offset += record.bytesize
    end

    header + entries + "\x00\x00" + records.join
  end

  def mobi_header_record(exth)
    exth_records = exth.map { |type, value| [ type, value.bytesize + 8, value ].pack("NNa*") }.join
    exth_block = "EXTH" + [ exth_block_length(exth_records), exth.size ].pack("NN") + exth_records
    mobi_header_length = 24
    ("\x00" * 16) + "MOBI" + [ mobi_header_length ].pack("N") +
      ("\x00" * (mobi_header_length - 8)) + exth_block
  end

  def write(path, exth: {})
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, build(exth: exth))
    path
  end

  def write_joint(path, exth: {})
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, build_joint(exth: exth))
    path
  end

  # A PalmDB/MOBI file with real text records, for Library::Mobi.raw_text
  # specs. `text_records` are the FULL on-disk record bytes (already
  # compressed and/or with trailing entries appended, as needed) — the
  # spec builds those explicitly so it controls exactly what's being
  # exercised; this just assembles the PalmDB container and a MOBI
  # header (with a real header length, so `extra_flags` lands at the
  # right offset) around them.
  def build_with_text(text_records:, text_length:, compression: 2, extra_flags: 0, mobi_header_length: 264)
    palmdoc_header = [ compression, 0, text_length, text_records.size, 4096, 0, 0 ].pack("nnNnnnn")
    mobi_header = "MOBI" + [ mobi_header_length ].pack("N") + ("\x00" * (mobi_header_length - 8))
    if mobi_header_length >= 0xF2 + 2
      mobi_header = mobi_header.dup
      mobi_header[0xF2, 2] = [ extra_flags ].pack("n")
    end

    record0 = palmdoc_header + mobi_header
    records = [ record0 ] + text_records

    header = "spec-rawtext".ljust(32, "\x00")
    header += [ 0, 0 ].pack("nn") + ([ 0 ] * 6).pack("N6")
    header += "BOOK" + "MOBI" + [ 0, 0 ].pack("NN")
    header += [ records.size ].pack("n")

    offset = header.bytesize + records.size * 8 + 2
    entries = +""
    records.each do |record|
      entries << [ offset, 0 ].pack("NN")
      offset += record.bytesize
    end

    header + entries + "\x00\x00" + records.join
  end

  def write_with_text(path, **kwargs)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, build_with_text(**kwargs))
    path
  end

  # A single-byte backward vint encoding a trailing entry of total size
  # `size` (<= 127), i.e. the vint IS the entire entry (no extra
  # payload) — the minimal case for exercising trailing-entry stripping.
  def trailing_entry(size)
    [ 0x80 | size ].pack("C")
  end
end
