class BookFile < ApplicationRecord
  # Everything Calibre can reasonably take as conversion input and that is
  # worth keeping in a private library.
  FORMATS = %w[epub azw3 azw mobi kfx pdf txt cbz cbr djvu docx fb2 html htmlz lit odt rtf].freeze
  SOURCES = %w[upload converted].freeze

  belongs_to :book

  validates :format, presence: true, inclusion: { in: FORMATS }, uniqueness: { scope: :book_id }
  validates :path, presence: true, uniqueness: true
  validates :sha256, presence: true
  validates :size, presence: true
  validates :source, inclusion: { in: SOURCES }

  after_destroy :remove_from_disk

  def absolute_path
    Library.root.join(path)
  end

  def filename
    File.basename(path)
  end

  def kindle_ready?
    Book::KINDLE_FORMATS.include?(format)
  end

  private

  def remove_from_disk
    FileUtils.rm_f(absolute_path)
  end
end
