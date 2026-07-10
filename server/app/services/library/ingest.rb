# Takes one uploaded/converted/scanned file and folds it into the library:
# dedupe by checksum, read metadata through Calibre (or take it pre-parsed,
# e.g. from a Calibre metadata.opf), place the file in the storage layout —
# or reference it where it lies (mode: :reference, used by the folder
# scanner; nothing is copied and the file is never deleted) — extract a
# cover, then queue search indexing and an automatic Kindle-format
# conversion when needed.
class Library::Ingest
  class UnsupportedFormat < StandardError; end

  Result = Struct.new(:book, :book_file, :duplicate) do
    def duplicate? = duplicate
  end

  # source_path: readable file on disk (tempfile from an upload is fine).
  # original_filename: used for format detection and metadata fallback.
  # book: attach the file to an existing book instead of creating one.
  # mode: :copy stores the file under Library.root; :reference records the
  #   absolute path in place.
  # metadata: pre-parsed metadata hash (skips the ebook-meta shell-out).
  # cover_source: path to a ready-made cover image (e.g. Calibre's
  #   cover.jpg) used instead of extracting one from the book file.
  def self.call(source_path, original_filename:, book: nil, source: "upload", enqueue_followups: true,
                mode: :copy, metadata: nil, cover_source: nil)
    new(source_path, original_filename, book, source, enqueue_followups, mode, metadata, cover_source).call
  end

  def initialize(source_path, original_filename, book, source, enqueue_followups, mode, metadata, cover_source)
    @source_path = Pathname.new(source_path)
    @original_filename = original_filename
    @book = book
    @source = source
    @enqueue_followups = enqueue_followups
    @mode = mode
    @metadata = metadata
    @cover_source = cover_source
  end

  def call
    format = detect_format!
    sha = Library.sha256(@source_path)

    if (existing = BookFile.find_by(sha256: sha))
      return Result.new(existing.book, existing, true)
    end

    book = @book || build_book(format)
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
    EnsureKindleFormatJob.perform_later(book.id) unless book.kindle_file
  end
end
