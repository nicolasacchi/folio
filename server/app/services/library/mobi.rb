# Minimal MOBI header reading. Sidecar positions are offsets into the
# book's uncompressed text, so percent estimates need the PalmDOC
# text_length, not the file size (which includes markup, images and
# indexes — off by 2x on a typical book).
module Library::Mobi
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
end
