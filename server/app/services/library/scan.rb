require "find"

# Folds every ebook under the configured scan roots (SCAN_ROOTS, comma
# separated) into the library Komga-style: files are referenced in place —
# nothing is copied, moved or deleted — so a read-only mount works.
#
# Incremental and idempotent:
#   * the import_files ledger skips paths whose size+mtime are unchanged,
#     so rescans don't re-hash tens of gigabytes;
#   * exact duplicates (sha256 already in the library) are recorded and
#     skipped;
#   * files that disappear are flagged missing and their book files marked
#     unavailable (drives/renames shouldn't destroy library records);
#   * books deleted in the UI stay deleted (their paths remain in the
#     ledger as "removed").
#
# Metadata: a directory containing metadata.opf is treated as one Calibre
# book — all its ebook formats attach to a single Book, with metadata and
# cover.jpg taken from the sidecars (no Calibre shell-out). Loose files are
# grouped by filename stem within a directory and fall back to ebook-meta.
# Search indexing is metadata-only here; full text extraction for a scanned
# book is opt-in from its page (Calibre-converting thousands of books up
# front would take days of CPU).
class Library::Scan
  Group = Struct.new(:paths, :opf, :cover)

  PROGRESS_CACHE_KEY = "library_scan/progress"

  def self.roots
    ENV.fetch("SCAN_ROOTS", "").split(",").filter_map do |raw|
      path = Pathname.new(raw.strip)
      path if raw.strip.present? && path.directory?
    end
  end

  def self.call(roots: self.roots)
    new(roots).call
  end

  def self.progress
    Rails.cache.read(PROGRESS_CACHE_KEY)
  end

  # Removes book files (and emptied books) whose scanned source file is
  # still gone, e.g. after a deliberate cleanup of the source folder.
  def self.prune_missing!
    pruned = 0
    ImportFile.where(status: "missing").find_each do |entry|
      next if File.exist?(entry.path)

      if (book_file = entry.book_file)
        book = book_file.book
        book_file.destroy!
        book.destroy! if book.book_files.reload.none?
      end
      entry.update!(status: "removed", book_file: nil)
      pruned += 1
    end
    pruned
  end

  def initialize(roots)
    @roots = roots
    @counts = Hash.new(0)
  end

  def call
    write_progress(state: "running", started_at: Time.current.to_i, done: 0, total: 0)
    groups = discover
    total = groups.sum { |group| group.paths.size }
    done = 0

    groups.each do |group|
      import_group(group)
      done += group.paths.size
      write_progress(state: "running", done: done, total: total) if (done % 20).zero?
    end

    mark_missing
    @counts[:unchanged] = @unchanged
    write_progress(state: "done", finished_at: Time.current.to_i, done: done, total: total, counts: @counts)
    @counts
  rescue StandardError => error
    write_progress(state: "failed", error: "#{error.class}: #{error.message}".first(300))
    raise
  end

  private

  # Walk the roots once, drop unchanged paths, and group what's left into
  # prospective books.
  def discover
    known = ImportFile.pluck(:path, :size, :mtime, :status)
                      .to_h { |path, size, mtime, status| [ path, [ size, mtime.to_i, status ] ] }
    @unchanged = 0
    groups = []

    @roots.each do |root|
      by_dir = Hash.new { |hash, key| hash[key] = [] }

      Find.find(root.to_s) do |entry|
        basename = File.basename(entry)
        if File.directory?(entry)
          # "_quarantine" and any other underscore-prefixed hold dir are
          # never scanned; "_inbox" is the one exception (see taxonomy).
          Find.prune if basename.start_with?(".") || (basename.start_with?("_") && basename != "_inbox")
          next
        end

        next if basename.start_with?(".") # e.g. a stray ".migrate_sha256.txt"
        next if basename.match?(/\AREADME\./i) && File.dirname(entry) == root.to_s

        extension = File.extname(basename).delete_prefix(".").downcase
        next unless BookFile::FORMATS.include?(extension)
        next unless File.readable?(entry) && File.size(entry).positive?

        by_dir[File.dirname(entry)] << entry
      end

      by_dir.each do |dir, paths|
        opf = existing_sidecar(dir, "metadata.opf")
        cover = existing_sidecar(dir, "cover.jpg")

        # A metadata.opf marks a Calibre book directory: every format in it
        # is one book. Elsewhere, same-stem files in a directory group up.
        clusters = opf ? [ paths ] : paths.group_by { |path| File.basename(path, ".*") }.values
        clusters.each do |cluster|
          fresh = cluster.reject { |path| skip_unchanged?(known, path) }
          groups << Group.new(sort_by_format(fresh), opf, cover) if fresh.any?
        end
      end
    end

    groups
  end

  def existing_sidecar(dir, name)
    path = File.join(dir, name)
    File.exist?(path) ? path : nil
  end

  def skip_unchanged?(known, path)
    size, mtime, status = known[path]
    return false if size.nil?
    # failed files get retried; missing files that reappeared get rescanned.
    return false if %w[failed missing].include?(status)

    stat = File.stat(path)
    unchanged = stat.size == size && stat.mtime.to_i == mtime
    @unchanged += 1 if unchanged
    unchanged
  rescue Errno::ENOENT
    false
  end

  # Ingest richer formats first so the book's identity comes from the best
  # source when there is no OPF sidecar.
  def sort_by_format(paths)
    paths.sort_by { |path| BookFile::FORMATS.index(File.extname(path).delete_prefix(".").downcase) || 99 }
  end

  def import_group(group)
    metadata = group.opf ? Library::Opf.parse(group.opf).presence : nil
    # One category per group — every path in a group shares a directory
    # (OPF dir or same-stem cluster), so the first path stands for all.
    category = Library::Category.from_path(group.paths.first, roots: @roots)
    # A format added to an already-imported book directory (or beside an
    # already-imported same-stem file) attaches to that book instead of
    # spawning a duplicate.
    book = existing_group_book(group)

    group.paths.each do |path|
      result = import_file(path, book: book, metadata: metadata, cover: group.cover, category: category)
      # Attach the group's remaining formats to the same book — including
      # the already-present book when the first file was a duplicate.
      book ||= result&.book
    end

    BookSearch.index_book!(book) if book&.persisted?
  end

  def existing_group_book(group)
    sample = group.paths.first
    prefix =
      if group.opf
        "#{File.dirname(sample)}/"
      else
        File.join(File.dirname(sample), File.basename(sample, ".*")) + "."
      end
    BookFile.where("path LIKE ?", "#{ActiveRecord::Base.sanitize_sql_like(prefix)}%").first&.book
  end

  def import_file(path, book:, metadata:, cover:, category:)
    stat = nil
    stat = File.stat(path)

    result =
      if (existing = BookFile.find_by(path: path))
        refresh_changed_file(existing, path, category)
      else
        Library::Ingest.call(path, original_filename: File.basename(path), book: book, source: "scan",
                             enqueue_followups: false, mode: :reference, metadata: metadata, cover_source: cover,
                             category: category, scan_roots: @roots)
      end

    @counts[:relocated] += 1 if result.relocated?
    status = result.duplicate? ? "duplicate" : "imported"
    @counts[status.to_sym] += 1
    record(path, stat, status: status, sha256: result.book_file.sha256, book_file: result.book_file,
                       message: result.duplicate? ? "same content as #{result.book_file.path}" : nil)
    result
  rescue Library::Ingest::UnsupportedFormat => error
    @counts[:skipped] += 1
    record(path, stat, status: "skipped", message: error.message)
    nil
  rescue StandardError => error
    @counts[:failed] += 1
    record(path, stat, status: "failed", message: "#{error.class}: #{error.message}".first(500))
    nil
  end

  # Same path, different content (or a file that was missing and came
  # back): refresh checksum/size and make it available again. The path
  # itself didn't move, so category is only filled in when blank, never
  # overwritten.
  def refresh_changed_file(book_file, path, category)
    book_file.update!(sha256: Library.sha256(path), size: File.size(path), available: true)
    book = book_file.book
    book.update!(category: category) if category.present? && book.category.blank?
    Library::Ingest::Result.new(book, book_file, false)
  end

  # stat may be nil when the file vanished mid-scan; record the failure
  # rather than aborting the whole run.
  def record(path, stat, status:, sha256: nil, book_file: nil, message: nil)
    entry = ImportFile.find_or_initialize_by(path: path)
    entry.assign_attributes(size: stat&.size || entry.size || 0, mtime: stat&.mtime || entry.mtime || Time.current,
                            status: status, sha256: sha256 || entry.sha256, book_file: book_file, message: message)
    entry.save!
  end

  def mark_missing
    ImportFile.where(status: %w[imported duplicate]).find_each do |entry|
      next if File.exist?(entry.path)

      entry.update!(status: "missing")
      entry.book_file&.update!(available: false)
      @counts[:missing] += 1
    end
  end

  def write_progress(**attributes)
    previous = Rails.cache.read(PROGRESS_CACHE_KEY) || {}
    Rails.cache.write(PROGRESS_CACHE_KEY, previous.merge(attributes), expires_in: 2.days)
  end
end
