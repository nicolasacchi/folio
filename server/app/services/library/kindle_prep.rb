# Produces the Kindle-delivery copy of a book file.
#
# Why (validated on a real 5.19.2 device): calibre-made MOBI/AZW3 files
# carry EXTH 501 = "EBOK" plus a uuid ASIN (112/113/504). The firmware
# treats such files as store books: it asks Amazon for the cover art,
# which can never resolve for a calibre uuid, and caches a "no image
# available" placeholder — the half-height, cover-less Library tiles. It
# never extracts the embedded cover for EBOK content. Personal documents
# (no store identity) DO get their embedded cover extracted and
# thumbnailed locally by the scanner, on every rescan.
#
# So preparation = get the book into a MOBI6 container, embed the catalog
# cover if the file has none, then rewrite the store identity in place:
# EXTH 501 becomes "PDOC" (same byte length as "EBOK") and the ASIN
# records' type ids are bumped into an unknown range. Values keep their
# length, so no structural rebuild is needed and KF8 offsets are
# untouched.
#
# Two more rules, both found the hard way on a real device:
# - 501 must be REWRITTEN, not dropped: without any cdeType the scanner
#   defaults MOBI6 rows to PDOC but leaves AZW3 rows typeless, and the
#   Library UI renders typeless rows as text tiles.
# - KF8-only AZW3 never gets a cover tile at all on 5.19 — the UI only
#   renders cover art for MOBI6-container books (and KFX). So AZW3
#   sources are transcoded to a joint MOBI6+KF8 file (the reader still
#   opens the KF8 half; the UI sees a MOBI6 container).
module Library
  module KindlePrep
    ASIN_EXTH = [ 112, 113, 504 ].freeze
    CDE_TYPE_EXTH = 501
    PERSONAL_DOC = "PDOC".b.freeze
    NEUTRAL_TYPE_OFFSET = 6000
    EXTH_COVER_OFFSET = 201
    PATCHABLE_FORMATS = %w[azw3 azw mobi prc].freeze
    COMBO_OPTIONS = [ "--mobi-file-type", "both" ].freeze

    module_function

    def root
      Library.base_root.join("prepared")
    end

    def preparable?(book_file)
      PATCHABLE_FORMATS.include?(book_file.format)
    end

    # Builds (or rebuilds) the prepared copy and records it on the row.
    # Returns the BookFile, or nil when the format can't be prepared.
    def prepare!(book_file)
      return nil unless preparable?(book_file)
      source = book_file.absolute_path
      return nil unless File.exist?(source)

      source_sha = book_file.sha256
      # A delivery needs BOTH halves: the MOBI6 shell for Library cover
      # tiles, the KF8 half for the modern reader (the mobi7 path renders
      # with the legacy chrome — no back/home buttons, no page numbers).
      # One MOBI header means either KF8-only azw3 or MOBI6-only mobi;
      # both go through calibre. Joint files just get byte-patched.
      transcode = Calibre.available? && mobi_header_count(source) < 2
      dest_format = transcode ? "mobi" : book_file.format
      dest = root.join("#{book_file.book.public_id}.#{dest_format}")
      # Named so ebook-convert infers the output format from the extension.
      staging = root.join("staging-#{book_file.book.public_id}.#{dest_format}")

      FileUtils.mkdir_p(root)
      begin
        if transcode
          begin
            Calibre.convert(source, staging, options: COMBO_OPTIONS)
          rescue Calibre::Error => error
            # A book that won't transcode still delivers as-is (text tile,
            # but readable) rather than not at all.
            Rails.logger.warn("combo transcode failed for #{book_file.book.public_id}: #{error.message}")
            dest_format = book_file.format
            dest = root.join("#{book_file.book.public_id}.#{dest_format}")
            staging = root.join("staging-#{book_file.book.public_id}.#{dest_format}")
            FileUtils.cp(source, staging)
          end
        else
          FileUtils.cp(source, staging)
        end
        # Cover first: ebook-meta rebuilds EXTH (and re-adds a calibre
        # uuid), so identity neutralization must come after.
        embed_cover(staging, book_file.book)
        neutralize_store_identity!(staging)
        # A previous prep may have used a different container format.
        FileUtils.rm_f(Dir.glob(root.join("#{book_file.book.public_id}.*").to_s))
        File.rename(staging, dest)
      ensure
        FileUtils.rm_f(staging)
      end

      identity = Library::MobiCde.parse(dest)
      book_file.update!(
        prepared_path: dest.relative_path_from(Library.base_root).to_s,
        prepared_sha256: Library.sha256(dest),
        prepared_size: File.size(dest),
        prepared_at: Time.current,
        prepared_source_sha256: source_sha,
        # The delivery copy is what devices see — its (neutralized)
        # identity replaces whatever was cached from the raw file.
        asin: identity[:asin],
        cde_type: identity[:cde_type],
        cde_parsed_at: Time.current
      )
      book_file
    end

    # In-place byte pokes, lengths unchanged: the ASIN records' type ids
    # move to unknown values the scanner ignores; cdeType's VALUE becomes
    # "PDOC" when it has the same length (the calibre case, "EBOK"),
    # otherwise the record is neutralized like the ASINs and the scanner's
    # MOBI6 default applies.
    #
    # Every record that looks like a MOBI header gets its EXTH patched:
    # joint MOBI6+KF8 files carry a second header (with its own EXTH copy)
    # in the KF8 section, and the scanner reads that one too.
    def neutralize_store_identity!(path)
      patched = false
      File.open(path, "r+b") do |io|
        header = io.read(78)
        return false unless header && header.bytesize == 78

        record_count = header[76, 2].unpack1("n")
        return false if record_count < 2

        io.seek(78)
        table = io.read(record_count * 8)
        return false unless table && table.bytesize == record_count * 8

        offsets = (0...record_count).map { |i| table[i * 8, 4].unpack1("N") }
        file_size = io.size
        bounds = offsets + [ file_size ]

        offsets.each_with_index do |offset, index|
          length = bounds[index + 1] - offset
          next if length < 24

          io.seek(offset)
          probe = io.read(24)
          next unless probe && probe[16, 4] == "MOBI"

          io.seek(offset)
          record = io.read([ length, 256 * 1024 ].min)
          patched |= patch_exth_block!(io, offset, record)
        end
      end
      patched
    end

    def patch_exth_block!(io, record_offset, record)
      exth_offset = 16 + record[20, 4].unpack1("N")
      return false unless record[exth_offset, 4] == "EXTH"

      count = record[exth_offset + 8, 4].unpack1("N")
      pos = exth_offset + 12
      count.times do
        type, length = record[pos, 8]&.unpack("NN")
        break if type.nil? || length.nil? || length < 8 || pos + length > record.bytesize
        if ASIN_EXTH.include?(type)
          io.seek(record_offset + pos)
          io.write([ type + NEUTRAL_TYPE_OFFSET ].pack("N"))
        elsif type == CDE_TYPE_EXTH
          if length - 8 == PERSONAL_DOC.bytesize
            io.seek(record_offset + pos + 8)
            io.write(PERSONAL_DOC)
          else
            io.seek(record_offset + pos)
            io.write([ type + NEUTRAL_TYPE_OFFSET ].pack("N"))
          end
        end
        pos += length
      end
      true
    end

    def embedded_cover?(path)
      records = Library::MobiCde.exth_records(path)
      records.present? && records.key?(EXTH_COVER_OFFSET)
    end

    # How many MOBI headers the PalmDB carries: 1 = single-format
    # (MOBI6-only or KF8-only azw3), 2 = joint MOBI6+KF8.
    def mobi_header_count(path)
      File.open(path, "rb") do |io|
        header = io.read(78)
        return 0 unless header && header.bytesize == 78

        record_count = header[76, 2].unpack1("n")
        return 0 if record_count < 1

        table = io.read(record_count * 8)
        return 0 unless table && table.bytesize == record_count * 8

        (0...record_count).count do |index|
          io.seek(table[index * 8, 4].unpack1("N"))
          probe = io.read(20)
          probe && probe[16, 4] == "MOBI"
        end
      end
    rescue Errno::ENOENT, Errno::EACCES
      0
    end

    def embed_cover(path, book)
      return unless book.cover?
      return if embedded_cover?(path)
      return unless Calibre.available?

      Calibre.run("ebook-meta", path.to_s, "--cover", Library.cover_path(book).to_s)
    rescue Calibre::Error => error
      # Old MOBI files without any cover record can refuse one; the book
      # still delivers, just with a generic extracted cover.
      Rails.logger.warn("cover embed failed for #{book.public_id}: #{error.message}")
    end
  end
end
