require "rubygems/package"
require "zlib"

# Best-effort reading-progress extraction from a synced `.sdr` sidecar
# bundle (tar.gz of the Kindle's per-book sidecar directory).
#
# Two sidecar generations, verified against real devices:
#
# - Old MBP (`.mbp`): "BPARMOBI" magic, tagged records, the first DATA
#   record holding the last-read position, BKMK records marking
#   bookmarks/annotations.
# - KRDS (`.mbs`, `.mbp1`, `.yjr`, `.azw3r`, ...): the lab126 "reader
#   data store" container (magic 00 00 00 00 00 1A B1 26) used by
#   KPP-era firmware (5.19+). The reading position lives in the `fpr`
#   (furthest position read) / `lpr` (last position read) objects as a
#   position string whose leading integer is an offset into the book's
#   uncompressed text. On this firmware the `.mbp1` only carries flags
#   and the annotation cache; positions are in the `.mbs`.
#
# Everything degrades to nil/0 rather than guessing when the bytes don't
# match — the sidecar inventory and its mtime are always trustworthy
# signals of reading activity even when position parsing isn't possible.
module Library::SidecarProgress
  MBP_MAGIC = "BPARMOBI".b.freeze
  KRDS_MAGIC = "\x00\x00\x00\x00\x00\x1A\xB1\x26".b.freeze
  MAX_MEMBER_BYTES = 4.megabytes

  Result = Struct.new(:files, :last_position, :annotation_count, :source, keyword_init: true)

  module_function

  def parse(bundle_path)
    members = read_bundle(bundle_path)
    files = members.keys.sort

    # Dispatch on content, not extension: KPP firmware reuses the .mbp1
    # suffix for KRDS blobs.
    mbp_bytes = members.values.find { |bytes| bytes&.start_with?(MBP_MAGIC) }
    if mbp_bytes && (parsed = parse_mbp(mbp_bytes))
      position, annotations = parsed
      return Result.new(files: files, last_position: position, annotation_count: annotations, source: "mbp")
    end

    krds_members = members.values.select { |bytes| bytes&.start_with?(KRDS_MAGIC) }
    if krds_members.any?
      position = krds_members.filter_map { |bytes| krds_position(bytes) }.max
      annotations = krds_members.sum { |bytes| bytes.scan("annotation.personal.".b).size }
      if position || annotations.positive?
        return Result.new(files: files, last_position: position, annotation_count: annotations, source: "krds")
      end
    end

    Result.new(files: files, last_position: nil, annotation_count: 0, source: "none")
  rescue Zlib::Error, Gem::Package::Error, Errno::ENOENT
    Result.new(files: [], last_position: nil, annotation_count: 0, source: "unreadable")
  end

  def read_bundle(bundle_path)
    members = {}
    Zlib::GzipReader.open(bundle_path.to_s) do |gz|
      Gem::Package::TarReader.new(gz) do |tar|
        tar.each do |entry|
          next unless entry.file? && entry.size <= MAX_MEMBER_BYTES
          members[File.basename(entry.full_name)] = entry.read.to_s.b
        end
      end
    end
    members
  end

  # Returns [last_position, annotation_count] or nil when the bytes don't
  # look like an MBP file.
  def parse_mbp(bytes)
    return nil unless bytes&.start_with?(MBP_MAGIC)

    annotations = bytes.scan("BKMK".b).size
    position = nil
    if (index = bytes.index("DATA".b))
      value = bytes[index + 4, 4]
      position = value.unpack1("N") if value&.bytesize == 4
    end
    [ position, annotations ]
  end

  # Best position in one KRDS blob: max of the leading integers of the
  # `fpr` and `lpr` position strings. Objects are encoded as
  #   FE 00 <u16 name length> <name> <typed values> FF
  # and a position value as
  #   [07 <version byte>] 03 00 <u16 length> "31740[:...]"
  # We locate the object markers instead of walking the full type system.
  def krds_position(bytes)
    %w[fpr lpr].filter_map { |name| krds_position_after(bytes, name) }.max
  end

  def krds_position_after(bytes, name)
    marker = "\xFE\x00\x00".b + [ name.length ].pack("C") + name.b
    index = bytes.index(marker)
    return nil unless index

    cursor = index + marker.bytesize
    cursor += 2 if bytes.getbyte(cursor) == 0x07 # version-prefixed variant
    return nil unless bytes.getbyte(cursor) == 0x03 && bytes.getbyte(cursor + 1)&.zero?

    length = bytes.byteslice(cursor + 2, 2)&.unpack1("n")
    value = length && bytes.byteslice(cursor + 4, length)
    position = value&.slice(/\A\d+/)
    position&.to_i
  end
end
