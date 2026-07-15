require "zlib"
require "rubygems/package"

# Pushes a reading position from the in-browser reader into a copy of the
# newest physical Kindle's .sdr bundle, so the existing device-sync
# pipeline (latest-content_mtime-wins, see ReadingState/Library) carries
# it back down to the hardware. Only rewrites Library::Krds position
# objects (lpr/fpr/...); every other bundle member is repacked verbatim.
module Reader
  module KindleWriteback
    # reason is nil on success, otherwise one of:
    #   :writeback_disabled    no physical device has opted in
    #   :no_reading_state      no physical device has synced anything for this book
    #   :stale                 basis_state is older than what's now on disk — caller should re-map
    #   :no_position_objects   the latest bundle has no KRDS member with a rewritable position
    #   :oversized_member      a bundle member exceeded MAX_MEMBER_BYTES (see read_bundle)
    Result = Struct.new(:written, :reason, keyword_init: true)

    # Per-member cap mirroring Library::SidecarProgress::MAX_MEMBER_BYTES —
    # real .sdr members (KRDS blobs, thumbnails) are tiny, so this is only
    # ever hit by a crafted/corrupt bundle. Unlike SidecarProgress (which is
    # read-only and can just skip an oversized member), write-back must
    # reject the whole bundle instead: it repacks every member byte-
    # identically, so silently dropping one would corrupt the rewritten
    # bundle rather than just losing a bit of best-effort progress data.
    MAX_MEMBER_BYTES = 4.megabytes

    class OversizedMember < StandardError; end

    module_function

    def call(book:, offset:, basis_state: nil)
      return not_written(:writeback_disabled) unless Device.physical.where(reader_writeback: true).exists?

      latest = latest_physical_state(book)
      return not_written(:no_reading_state) unless latest

      return not_written(:stale) if basis_state && latest.content_mtime > basis_state.content_mtime

      members = read_bundle(latest.absolute_path)
      write_at = [ Time.now, latest.content_mtime + 1 ].max
      rewritten, changed = rewrite_members(members, offset, write_at)
      return not_written(:no_position_objects) unless changed

      bytes = write_tar_gz(rewritten)
      web_device = Device.web_reader!
      path = Library.reading_state_path(book, web_device)
      write_atomically(path, bytes)
      state = upsert_web_reading_state(book, web_device, path, bytes, write_at)
      ParseSidecarJob.perform_later(state.id)

      Result.new(written: true, reason: nil)
    rescue Zlib::Error, Gem::Package::Error, Errno::ENOENT
      not_written(:unreadable_bundle)
    rescue OversizedMember
      not_written(:oversized_member)
    end

    def not_written(reason)
      Result.new(written: false, reason: reason)
    end

    def latest_physical_state(book)
      book.reading_states.joins(:device).merge(Device.physical).order(content_mtime: :desc).first
    end

    # -- bundle rebuild ------------------------------------------------

    # Keys are each member's full in-archive path (not basename — unlike
    # Library::SidecarProgress's read, which only needs to sniff content
    # and doesn't care about directory structure, write-back must repack
    # the bundle with the exact same member names).
    def read_bundle(path)
      members = {}
      Zlib::GzipReader.open(path.to_s) do |gz|
        Gem::Package::TarReader.new(gz) do |tar|
          tar.each do |entry|
            next unless entry.file?
            raise OversizedMember, "#{entry.full_name} is #{entry.size} bytes" if entry.size > MAX_MEMBER_BYTES

            members[entry.full_name] = entry.read.to_s.b
          end
        end
      end
      members
    end

    # Rewrites the position in every KRDS member that has one, leaving
    # everything else (non-KRDS members, and KRDS members with no
    # rewritable position, e.g. an annotation-only .mbp1) byte-identical.
    def rewrite_members(members, offset, at)
      changed = false
      rewritten = members.transform_values do |bytes|
        next bytes unless Library::Krds.krds?(bytes)

        updated = Library::Krds.update_positions(bytes, offset, at: at)
        next bytes unless updated

        changed = true
        updated
      end
      [ rewritten, changed ]
    end

    def write_tar_gz(members)
      tar_io = StringIO.new.tap { |io| io.set_encoding(Encoding::BINARY) }
      Gem::Package::TarWriter.new(tar_io) do |tar|
        members.each do |name, bytes|
          tar.add_file_simple(name, 0o644, bytes.bytesize) { |io| io.write(bytes) }
        end
      end

      gz_io = StringIO.new.tap { |io| io.set_encoding(Encoding::BINARY) }
      gz = Zlib::GzipWriter.new(gz_io)
      gz.write(tar_io.string)
      gz.close
      gz_io.string
    end

    def write_atomically(path, bytes)
      FileUtils.mkdir_p(path.dirname)
      tmp = Pathname.new("#{path}.tmp-#{SecureRandom.hex(8)}")
      File.binwrite(tmp, bytes)
      File.rename(tmp, path)
    end

    def upsert_web_reading_state(book, web_device, path, bytes, content_mtime)
      state = ReadingState.find_or_initialize_by(book: book, device: web_device)
      state.update!(
        path: path.relative_path_from(Library.reading_states_root).to_s,
        content_mtime: content_mtime,
        size: bytes.bytesize,
        sha256: Digest::SHA256.hexdigest(bytes)
      )
      state
    end
  end
end
