require "rubygems/package"
require "zlib"

# Best-effort reading-progress extraction from a synced `.sdr` sidecar
# bundle (tar.gz of the Kindle's per-book sidecar directory).
#
# The capture research (observer/README.md) showed sideloaded books get
# MBP-family sidecars (`.mbp1`, `.mbs`) on this firmware. MBP is the old
# MOBI bookmark format: "BPARMOBI" magic, tagged records, the first DATA
# record holding the last-read position and BKMK records marking
# bookmarks/annotations. Everything here degrades to nil/0 rather than
# guessing when the bytes don't match — the sidecar inventory and its
# mtime are always trustworthy signals of reading activity even when
# position parsing isn't possible (e.g. KRDS `.azw3r` sidecars, which we
# inventory but don't parse yet).
module Library::SidecarProgress
  MBP_MAGIC = "BPARMOBI".b.freeze
  MAX_MEMBER_BYTES = 4.megabytes

  Result = Struct.new(:files, :last_position, :annotation_count, :source, keyword_init: true)

  module_function

  def parse(bundle_path)
    members = read_bundle(bundle_path)
    files = members.keys.sort

    mbp_name = files.find { |name| name =~ /\.mbp\d*\z/i }
    if mbp_name && (parsed = parse_mbp(members[mbp_name]))
      position, annotations = parsed
      Result.new(files: files, last_position: position, annotation_count: annotations, source: "mbp")
    else
      Result.new(files: files, last_position: nil, annotation_count: 0, source: "none")
    end
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
end
