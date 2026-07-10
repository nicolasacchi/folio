class Book < ApplicationRecord
  # Formats the stock Kindle reader opens directly, in delivery preference
  # order. EPUB is not on this list on purpose: firmware 5.x cannot open it.
  KINDLE_FORMATS = %w[azw3 kfx azw mobi prc txt pdf].freeze

  has_many :book_files, dependent: :destroy
  has_many :conversions, dependent: :destroy
  has_many :reading_states, dependent: :destroy

  # Assigned eagerly (not at validation) because the storage path of an
  # about-to-be-ingested file already depends on it.
  after_initialize :assign_public_id, if: :new_record?

  validates :public_id, presence: true, uniqueness: true
  validates :title, presence: true

  after_destroy :remove_artifacts

  SearchHit = Struct.new(:book, :snippet, :rank)

  # FTS5-ranked search. Returns SearchHit structs so views can show the
  # matching fulltext snippet next to each book.
  def self.search(query)
    hits = BookSearch.search(query)
    books = where(id: hits.map { |hit| hit[:book_id] }).index_by(&:id)
    hits.filter_map do |hit|
      book = books[hit[:book_id]]
      SearchHit.new(book, hit[:snippet], hit[:rank]) if book
    end
  end

  def kindle_file
    by_format = book_files.select(&:available?).index_by(&:format)
    KINDLE_FORMATS.each do |format|
      file = by_format[format]
      return file if file
    end
    nil
  end

  def file_for(format)
    book_files.find_by(format: format)
  end

  def formats
    book_files.order(:format).pluck(:format)
  end

  def latest_reading_state
    reading_states.order(content_mtime: :desc).first
  end

  def cover_path
    Library.cover_path(self)
  end

  def cover?
    File.exist?(cover_path)
  end

  def display_author
    author.presence || "Unknown author"
  end

  private

  def assign_public_id
    self.public_id ||= SecureRandom.hex(10)
  end

  def remove_artifacts
    BookSearch.remove_book!(id)
    Library::Embeddings.remove_book!(id)
    Library.remove_book_artifacts(self)
  end
end
