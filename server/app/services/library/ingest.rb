# Takes one uploaded/converted/scanned file and folds it into the library:
# dedupe by checksum, read metadata through Calibre (or take it pre-parsed,
# e.g. from a Calibre metadata.opf), place the file in the storage layout —
# or reference it where it lies (mode: :reference, used by the folder
# scanner; nothing is copied and the file is never deleted) — extract a
# cover, then queue search indexing and an automatic Kindle-format
# conversion when needed.
#
# Relocation: when scan_roots is given (scan-driven :reference ingests
# only), a sha256 match whose row points at a path that no longer exists,
# or that exists but has drifted outside the current scan roots, is
# repointed at the newly discovered path instead of being treated as a
# duplicate — the Book and all its associations survive a library reorg.
class Library::Ingest
  class UnsupportedFormat < StandardError; end

  Result = Struct.new(:book, :book_file, :duplicate, :relocated) do
    def duplicate? = duplicate
    def relocated? = !!relocated
  end

  # source_path: readable file on disk (tempfile from an upload is fine).
  # original_filename: used for format detection and metadata fallback.
  # book: attach the file to an existing book instead of creating one.
  # mode: :copy stores the file under Library.root; :reference records the
  #   absolute path in place.
  # metadata: pre-parsed metadata hash (skips the ebook-meta shell-out).
  # cover_source: path to a ready-made cover image (e.g. Calibre's
  #   cover.jpg) used instead of extracting one from the book file.
  # category: books.category to set on create, fill (if blank) on an
  #   existing book, or overwrite on relocation.
  # scan_roots: current scan roots; enables relocation (nil keeps today's
  #   plain-duplicate behavior — the default for uploads/conversions).
  def self.call(source_path, original_filename:, book: nil, source: "upload", enqueue_followups: true,
                mode: :copy, metadata: nil, cover_source: nil, category: nil, scan_roots: nil)
    new(source_path, original_filename, book, source, enqueue_followups, mode, metadata, cover_source, category,
        scan_roots).call
  end

  def initialize(source_path, original_filename, book, source, enqueue_followups, mode, metadata, cover_source,
                 category, scan_roots)
    @source_path = Pathname.new(source_path)
    @original_filename = original_filename
    @book = book
    @source = source
    @enqueue_followups = enqueue_followups
    @mode = mode
    @metadata = metadata
    @cover_source = cover_source
    @category = category
    @scan_roots = scan_roots
  end

  def call
    format = detect_format!
    sha = Library.sha256(@source_path)
    candidates = BookFile.where(sha256: sha).to_a

    if candidates.any?
      target = relocation_target(candidates)
      return relocate(target) if target
      return Result.new(candidates.first.book, candidates.first, true, false)
    end

    book = @book || build_book(format)
    book.category = @category if @category.present? && book.category.blank?
    raise UnsupportedFormat, "book already has a #{format} file" if book.persisted? && book.file_for(format)

    destination = nil
    if @mode == :reference
      stored_path = @source_path.to_s
    else
      destination = Library.file_path(book, format)
      FileUtils.mkdir_p(destination.dirname)
      FileUtils.cp(@source_path, destination)
      stored_path = destination.relative_path_from(Library.root).to_s
    end

    book_file = nil
    Book.transaction do
      book.save!
      book_file = book.book_files.create!(
        format: format,
        path: stored_path,
        size: File.size(@mode == :reference ? @source_path : destination),
        sha256: sha,
        source: @source
      )
    end

    extract_cover(book, @mode == :reference ? @source_path : destination)
    enqueue_followups(book) if @enqueue_followups

    Result.new(book, book_file, false)
  rescue StandardError
    FileUtils.rm_f(destination) if destination && book_file.nil?
    raise
  end

  private

  # Picks the sha256-matching row to repoint at @source_path, or nil when
  # relocation isn't applicable (uploads/conversions, or every match is a
  # genuine still-in-place duplicate).
  def relocation_target(candidates)
    return nil unless @mode == :reference && @scan_roots.present?
    return nil if BookFile.exists?(path: @source_path.to_s) # guard: path already owned, never happens via Scan

    eligible = candidates.select { |book_file| relocatable?(book_file) }
    return nil if eligible.empty?

    # Missing-on-disk rows are stronger evidence of "this is the moved
    # copy" than a still-present-but-out-of-tree hardlink.
    eligible.min_by { |book_file| File.exist?(book_file.absolute_path) ? 1 : 0 }
  end

  # External rows only: an internal (mode :copy, app-owned) file whose
  # stored copy went missing must never be silently repointed at a scan
  # file that happens to share its content.
  def relocatable?(book_file)
    book_file.external? &&
      (!File.exist?(book_file.absolute_path) || !under_scan_roots?(book_file.path))
  end

  def under_scan_roots?(path)
    @scan_roots.any? { |root| path.start_with?("#{root.to_s.chomp('/')}/") }
  end

  # Repoints an existing row at the newly discovered path instead of
  # recording a duplicate — the book and its annotations/reading
  # states/deliveries are untouched. The stale path's ImportFile ledger
  # entry is closed out so it's never resurrected by mark_missing or
  # pruned by prune_missing!.
  def relocate(book_file)
    old_path = book_file.path
    new_path = @source_path.to_s
    book = book_file.book

    Book.transaction do
      book_file.update!(path: new_path, available: true, source: @source)
      # Overwrite (not fill-if-blank) is deliberate: a relocation means the
      # file moved shelves on disk, and the path is the source of truth for
      # scanned books — a stale manual override loses to a real move.
      book.update!(category: @category) if @category.present?
      ImportFile.where(path: old_path).update_all(
        status: "removed", book_file_id: nil, message: "relocated to #{new_path}"
      )
    end

    Result.new(book, book_file, false, true)
  end

  def detect_format!
    format = File.extname(@original_filename.to_s).delete_prefix(".").downcase
    unless BookFile::FORMATS.include?(format)
      raise UnsupportedFormat, "unsupported format: #{format.presence || 'none'}"
    end
    format
  end

  def build_book(format)
    meta = @metadata || calibre_metadata
    title = meta[:title].presence
    author = meta[:author].presence
    fallback_title, fallback_author = split_stem(File.basename(@original_filename.to_s, ".*").strip)

    # Formats without embedded metadata make ebook-meta echo the file stem
    # back as the title — worthless for uploads (Rack tempfile names).
    title = nil if title == @source_path.basename(".*").to_s

    # For bare formats (txt, pdf without metadata) ebook-meta reports the
    # filename stem as the title; split "Title -- Author" out of it.
    if title && author.nil?
      split_title, split_author = split_stem(title)
      title, author = split_title, split_author if split_author
    end

    Book.new(
      title: title || fallback_title.presence || "Untitled",
      author: author || fallback_author,
      series: meta[:series],
      series_index: meta[:series_index],
      language: meta[:language],
      description: meta[:description],
      published_year: meta[:published_year]
    )
  end

  def calibre_metadata
    Calibre.metadata(@source_path)
  rescue Calibre::Error
    {}
  end

  # "Title -- Author" or "Title - Author", as used by the existing
  # sideload convention.
  def split_stem(stem)
    [ " -- ", " - " ].each do |separator|
      next unless stem.include?(separator)
      title, author = stem.split(separator, 2)
      return [ title.strip.presence || stem, author.strip.presence ]
    end
    [ stem, nil ]
  end

  def extract_cover(book, file_path)
    return if book.cover?
    FileUtils.mkdir_p(Library.covers_root)
    if @cover_source && File.exist?(@cover_source)
      FileUtils.cp(@cover_source, Library.cover_path(book))
    else
      Calibre.extract_cover(file_path, Library.cover_path(book))
    end
  end

  def enqueue_followups(book)
    IndexBookJob.perform_later(book.id)
    EmbedBookJob.perform_later(book.id) if Library::Embeddings.available?
    EnsureKindleFormatJob.perform_later(book.id) unless book.kindle_file
  end
end
