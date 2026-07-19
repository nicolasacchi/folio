# Reconciles the on-disk prepared-delivery and cover/thumbnail directories
# against the database, deleting anything that isn't referenced by any row.
#
# These three directories hold exclusively *regenerable* artifacts —
# Library::KindlePrep and Library::Thumbnails rebuild them on demand, and
# Library.remove_book_artifacts / BookFile#remove_from_disk clean them up on
# the normal destroy paths. This sweep is the safety net for what slips past
# those paths: a crash between writing the file and committing the DB row, a
# renamed prepared file, or a bug. It deliberately excludes Library.root
# (original uploads + conversions — not regenerable, and the ledger of
# record) and Library.reading_states_root (user reading progress, not
# regenerable); a bug there would destroy real data, not just cached
# delivery copies.
module Library
  module StorageGc
    # A prep job (Library::KindlePrep.prepare!, Library::Thumbnails.ensure)
    # writes its file to disk before the row that references it commits —
    # the grace period keeps a fresh, not-yet-referenced file from being
    # swept out from under an in-flight write.
    ORPHAN_GRACE = 6.hours

    Stats = Struct.new(:removed, :bytes_reclaimed, keyword_init: true)

    module_function

    # Directories that hold only DB-referenced, regenerable artifacts.
    def swept_directories
      [ Library::KindlePrep.root, Library.covers_root, Library::Thumbnails.root ]
    end

    # Absolute paths (as strings) every swept directory is allowed to
    # contain right now, per the database.
    def referenced_paths
      referenced = Set.new

      BookFile.where.not(prepared_path: [ nil, "" ]).pluck(:prepared_path).each do |relative|
        referenced << Library.base_root.join(relative).to_s
      end

      Book.pluck(:public_id).each do |public_id|
        referenced << Library.covers_root.join("#{public_id}.jpg").to_s
        referenced << Library::Thumbnails.root.join("#{public_id}.jpg").to_s
      end

      referenced
    end

    # Deletes any file under swept_directories that isn't in
    # referenced_paths and is older than ORPHAN_GRACE. Returns a Stats with
    # the count and total bytes reclaimed, and logs the same summary.
    def sweep!(grace: ORPHAN_GRACE)
      referenced = referenced_paths
      cutoff = Time.current - grace
      removed = 0
      bytes = 0

      swept_directories.each do |dir|
        next unless Dir.exist?(dir)

        Dir.glob(dir.join("**", "*")).each do |path|
          next unless File.file?(path)
          next if referenced.include?(path)
          next if File.mtime(path) > cutoff

          size = File.size(path)
          FileUtils.rm_f(path)
          removed += 1
          bytes += size
        rescue Errno::ENOENT
          # Raced with something else removing the same file — fine.
          next
        end
      end

      Rails.logger.info("Library::StorageGc swept #{removed} orphaned file(s), #{bytes} bytes reclaimed")
      Stats.new(removed: removed, bytes_reclaimed: bytes)
    end
  end
end
