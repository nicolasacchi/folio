# Storage layout for book files, covers and reading-state bundles.
#
#   <root>/<public_id>/<Title -- Author>.<format>   book files
#   <covers_root>/<public_id>.jpg                   covers
#   <reading_states_root>/<public_id>/<device_id>.tar.gz
#
# Roots default to Rails storage/ and can be moved with LIBRARY_ROOT.
module Library
  module_function

  def base_root
    Pathname.new(ENV.fetch("LIBRARY_ROOT", Rails.root.join("storage").to_s))
  end

  def root
    base_root.join("library")
  end

  def covers_root
    base_root.join("covers")
  end

  def reading_states_root
    base_root.join("reading_states")
  end

  def file_path(book, format)
    root.join(book.public_id, "#{filename_stem(book)}.#{format}")
  end

  def cover_path(book)
    covers_root.join("#{book.public_id}.jpg")
  end

  def reading_state_path(book, device)
    reading_states_root.join(book.public_id, "device-#{device.id}.tar.gz")
  end

  def remove_book_artifacts(book)
    FileUtils.rm_rf(root.join(book.public_id))
    FileUtils.rm_f(cover_path(book))
    FileUtils.rm_rf(reading_states_root.join(book.public_id))
    FileUtils.rm_f(Dir.glob(base_root.join("prepared", "#{book.public_id}.*").to_s))
    FileUtils.rm_f(base_root.join("thumbnails", "#{book.public_id}.jpg"))
  end

  # "Title -- Author" mirrors the sideload naming convention the Kindle
  # falls back to when a file has no embedded metadata.
  def filename_stem(book)
    stem = [ book.title, book.author.presence ].compact.join(" -- ")
    sanitize_filename(stem)
  end

  def sanitize_filename(name)
    cleaned = name.gsub(%r{[/\\:*?"<>|\x00-\x1f]}, " ").squeeze(" ").strip
    cleaned = cleaned.byteslice(0, 120).to_s.scrub("").strip
    cleaned.presence || "book"
  end

  def sha256(path)
    Digest::SHA256.file(path).hexdigest
  end
end
