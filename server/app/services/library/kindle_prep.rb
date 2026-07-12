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
# So preparation = copy the file, embed the catalog cover if the file has
# none, then rewrite the store identity in place: EXTH 501 becomes "PDOC"
# (same byte length as "EBOK") and the ASIN records' type ids are bumped
# into an unknown range. Values keep their length, so no structural
# rebuild is needed and KF8 offsets are untouched.
#
# 501 must be REWRITTEN, not dropped: without any cdeType the scanner
# defaults MOBI6 rows to PDOC but leaves AZW3/KF8 rows typeless, and the
# Library UI renders typeless rows as text tiles even though it extracted
# a perfectly good cover thumbnail (found the hard way on-device).
module Library
  module KindlePrep
    ASIN_EXTH = [ 112, 113, 504 ].freeze
    CDE_TYPE_EXTH = 501
    PERSONAL_DOC = "PDOC".b.freeze
    NEUTRAL_TYPE_OFFSET = 6000
    EXTH_COVER_OFFSET = 201
    PATCHABLE_FORMATS = %w[azw3 azw mobi prc].freeze

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
      dest = root.join("#{book_file.book.public_id}.#{book_file.format}")
      staging = Pathname.new("#{dest}.tmp")

      FileUtils.mkdir_p(root)
      FileUtils.cp(source, staging)
      begin
        # Cover first: ebook-meta rebuilds EXTH (and re-adds a calibre
        # uuid), so identity neutralization must come after.
        embed_cover(staging, book_file.book)
        neutralize_store_identity!(staging)
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
    def neutralize_store_identity!(path)
      File.open(path, "r+b") do |io|
        header = io.read(86)
        return false unless header && header.bytesize == 86 && header[76, 2].unpack1("n") >= 2

        rec0_offset = header[78, 4].unpack1("N")
        io.seek(86)
        rec1_offset = io.read(4)&.unpack1("N")
        return false unless rec1_offset && rec1_offset > rec0_offset

        io.seek(rec0_offset)
        rec0 = io.read([ rec1_offset - rec0_offset, 256 * 1024 ].min)
        return false unless rec0 && rec0[16, 4] == "MOBI"

        exth_offset = 16 + rec0[20, 4].unpack1("N")
        return false unless rec0[exth_offset, 4] == "EXTH"

        count = rec0[exth_offset + 8, 4].unpack1("N")
        pos = exth_offset + 12
        count.times do
          type, length = rec0[pos, 8]&.unpack("NN")
          break if type.nil? || length.nil? || length < 8 || pos + length > rec0.bytesize
          if ASIN_EXTH.include?(type)
            io.seek(rec0_offset + pos)
            io.write([ type + NEUTRAL_TYPE_OFFSET ].pack("N"))
          elsif type == CDE_TYPE_EXTH
            if length - 8 == PERSONAL_DOC.bytesize
              io.seek(rec0_offset + pos + 8)
              io.write(PERSONAL_DOC)
            else
              io.seek(rec0_offset + pos)
              io.write([ type + NEUTRAL_TYPE_OFFSET ].pack("N"))
            end
          end
          pos += length
        end
      end
      true
    end

    def embedded_cover?(path)
      records = Library::MobiCde.exth_records(path)
      records.present? && records.key?(EXTH_COVER_OFFSET)
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
