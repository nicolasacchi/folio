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

  def write(path, exth: {})
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, build(exth: exth))
    path
  end
end
