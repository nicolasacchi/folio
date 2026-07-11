# Read-only extractor for the Kindle catalog identity embedded in
# MOBI/AZW/AZW3 files: EXTH record 113/504 (ASIN — for calibre output a
# uuid) and 501 (cdeType, "EBOK"/"PDOC").
#
# Why it matters: firmware only auto-generates Library thumbnails for
# PDOC files. For cdeType=EBOK it expects to fetch the cover from Amazon
# by ASIN — which never resolves for calibre uuids — so sideloaded EBOK
# books render as cover-less half-height rows. Knowing the exact
# ASIN/cdeType lets the manifest deliver a thumbnail named
# `thumbnail_<asin>_<cdeType>_portrait.jpg`, which the firmware picks up.
#
# PalmDB layout: 78-byte header, then 8 bytes per record entry (offset +
# flags). Record 0 holds the PalmDOC header (16 bytes), the MOBI header,
# then the EXTH block ("EXTH", length, count, then (type,len,data) records).
module Library
  module MobiCde
    EXTH_ASIN = [ 113, 504 ].freeze
    EXTH_CDE_TYPE = 501

    module_function

    def parse(path)
      empty = { asin: nil, cde_type: nil }
      records = exth_records(path)
      return empty unless records

      asin = EXTH_ASIN.filter_map { |type| clean(records[type]) }.first
      { asin: asin, cde_type: clean(records[EXTH_CDE_TYPE]) }
    rescue Errno::ENOENT, Errno::EACCES
      empty
    end

    def exth_records(path)
      File.open(path, "rb") do |io|
        header = io.read(86)
        return nil unless header && header.bytesize == 86

        num_records = header[76, 2].unpack1("n")
        return nil if num_records < 2

        rec0_offset = header[78, 4].unpack1("N")
        io.seek(78 + 8)
        rec1_offset = io.read(4)&.unpack1("N")
        return nil unless rec1_offset && rec1_offset > rec0_offset

        io.seek(rec0_offset)
        rec0 = io.read([ rec1_offset - rec0_offset, 128 * 1024 ].min)
        return nil unless rec0 && rec0[16, 4] == "MOBI"

        mobi_length = rec0[20, 4].unpack1("N")
        exth_offset = 16 + mobi_length
        return nil unless rec0[exth_offset, 4] == "EXTH"

        count = rec0[exth_offset + 8, 4].unpack1("N")
        pos = exth_offset + 12
        records = {}
        count.times do
          type, length = rec0[pos, 8]&.unpack("NN")
          break if type.nil? || length.nil? || length < 8 || pos + length > rec0.bytesize
          records[type] ||= rec0[pos + 8, length - 8]
          pos += length
        end
        records
      end
    end

    def clean(value)
      value&.dup&.force_encoding(Encoding::UTF_8)&.scrub&.strip.presence
    end
  end
end
