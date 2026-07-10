# Takes one uploaded/converted file and folds it into the library:
# dedupe by checksum, read metadata through Calibre, place the file in the
# storage layout, extract a cover, then queue search indexing and an
# automatic Kindle-format conversion when needed.
class Library::Ingest
  class UnsupportedFormat < StandardError; end

  Result = Struct.new(:book, :book_file, :duplicate) do
    def duplicate? = duplicate
  end

  # source_path: readable file on disk (tempfile from an upload is fine).
  # original_filename: used for format detection and metadata fallback.
  # book: attach the file to an existing book instead of creating one.
  def self.call(source_path, original_filename:, book: nil, source: "upload", enqueue_followups: true)
    new(source_path, original_filename, book, source, enqueue_followups).call
  end

  def initialize(source_path, original_filename, book, source, enqueue_followups)
    @source_path = Pathname.new(source_path)
    @original_filename = original_filename
    @book = book
    @source = source
    @enqueue_followups = enqueue_followups
  end

  def call
    format = detect_format!
    sha = Library.sha256(@source_path)

    if (existing = BookFile.find_by(sha256: sha))
      return Result.new(existing.book, existing, true)
    end

    book = @book || build_book(format)
    raise UnsupportedFormat, "book already has a #{format} file" if book.persisted? && book.file_for(format)

    destination = Library.file_path(book, format)
    FileUtils.mkdir_p(destination.dirname)
    FileUtils.cp(@source_path, destination)

    book_file = nil
    Book.transaction do
      book.save!
      book_file = book.book_files.create!(
        format: format,
        path: destination.relative_path_from(Library.root).to_s,
        size: File.size(destination),
        sha256: sha,
        source: @source
      )
    end

    extract_cover(book, destination)
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
    meta = calibre_metadata
    fallback_title, fallback_author = title_author_from_filename

    Book.new(
      title: meta[:title].presence || fallback_title,
      author: meta[:author].presence || fallback_author,
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

  # "Title -- Author.ext" or "Title - Author.ext", as used by the existing
  # sideload convention.
  def title_author_from_filename
    stem = File.basename(@original_filename.to_s, ".*").strip
    [ " -- ", " - " ].each do |separator|
      next unless stem.include?(separator)
      title, author = stem.split(separator, 2)
      return [ title.strip.presence || stem, author.strip ]
    end
    [ stem.presence || "Untitled", nil ]
  end

  def extract_cover(book, file_path)
    return if book.cover?
    FileUtils.mkdir_p(Library.covers_root)
    Calibre.extract_cover(file_path, Library.cover_path(book))
  end

  def enqueue_followups(book)
    IndexBookJob.perform_later(book.id)
    EnsureKindleFormatJob.perform_later(book.id) unless book.kindle_file
  end
end
