class Book < ApplicationRecord
  # Formats the stock Kindle reader opens directly, in delivery preference
  # order. EPUB is not on this list on purpose: firmware 5.x cannot open it.
  KINDLE_FORMATS = %w[azw3 kfx azw mobi prc txt pdf].freeze

  # Formats the in-browser reader (foliate-js) can open, in preference
  # order — richest/most-reflowable first. PDF is last: foliate-js renders
  # it via a vendored pdf.js wrapper rather than reflowing text, so it's a
  # last resort rather than a peer of the reflowable formats. KFX is
  # deliberately excluded — it's a proprietary Amazon container foliate-js
  # cannot parse.
  READABLE_FORMATS = %w[epub azw3 azw mobi prc fb2 cbz txt pdf].freeze

  # Progress percent above which a book counts as "finished" rather than
  # "currently reading" — used by .currently_reading (drops it off that
  # shelf) and by SmartShelf's read_state condition (see
  # SmartShelf.read_state_scope), so the two stay in lockstep.
  READING_FINISHED_THRESHOLD = 96

  has_many :book_files, dependent: :destroy
  has_many :conversions, dependent: :destroy
  has_many :reading_states, dependent: :destroy
  has_many :deliveries, dependent: :destroy
  has_many :annotations, dependent: :nullify
  has_many :reader_positions, dependent: :destroy

  # Assigned eagerly (not at validation) because the storage path of an
  # about-to-be-ingested file already depends on it.
  after_initialize :assign_public_id, if: :new_record?

  validates :public_id, presence: true, uniqueness: true
  validates :title, presence: true
  # "category" or "category/subcategory", lowercase kebab keys from
  # docs/library-taxonomy.yml; nil/blank means uncategorized (uploads with
  # no scan path). "_inbox" is a valid single segment.
  validates :category, format: { with: %r{\A[a-z0-9_]+(?:/[a-z0-9_]+)?\z} }, allow_blank: true

  scope :in_category, ->(category) { where(category: category) }
  scope :in_category_root, ->(root) { where("category = ? OR category LIKE ?", root, "#{sanitize_sql_like(root)}/%") }

  after_destroy :remove_artifacts

  SearchHit = Struct.new(:book, :snippet, :rank)

  # FTS5-ranked search. Returns SearchHit structs so views can show the
  # matching fulltext snippet next to each book.
  def self.search(query, scope: :all)
    hits = BookSearch.search(query, scope: scope)
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

  # Best format for the in-browser reader, see READABLE_FORMATS.
  def readable_file
    by_format = book_files.select(&:available?).index_by(&:format)
    READABLE_FORMATS.each do |format|
      file = by_format[format]
      return file if file
    end
    nil
  end

  def formats
    book_files.order(:format).pluck(:format)
  end

  # Flags a book for the shelf badge: some conversion attempt failed and
  # nothing Kindle-ready ever landed — i.e. there's genuinely no
  # deliverable file to fall back on. A book that failed one target but
  # still has a good file from another isn't flagged (kindle_file wins).
  # Reads off already-loaded book_files/conversions (see
  # BooksController#index's .includes(:book_files, :conversions)) so this
  # never issues a query of its own when called across a shelf of books.
  def conversion_failed_without_deliverable?
    conversions.any?(&:failed?) && kindle_file.nil?
  end

  def latest_reading_state
    reading_states.order(content_mtime: :desc).first
  end

  # Books someone is in the middle of, freshest activity first. "Finished"
  # (~>96%) drops off the shelf; books with unparseable progress stay (the
  # content_mtime signal alone still means "recently opened").
  def self.currently_reading(limit: 12)
    latest = ReadingState.select("book_id, MAX(content_mtime) AS content_mtime")
      .group(:book_id).order("content_mtime DESC").limit(limit * 2)
    states = ReadingState.where(book_id: latest.map(&:book_id)).includes(:device)
      .group_by(&:book_id)
    books = where(id: states.keys).index_by(&:id)
    latest.filter_map { |row|
      book = books[row.book_id]
      next unless book
      state = states[row.book_id].max_by(&:content_mtime)
      next if state.progress_percent && state.progress_percent > READING_FINISHED_THRESHOLD
      [ book, state ]
    }.first(limit)
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

  def category_parts
    category.to_s.split("/", 2)
  end

  def category_root
    category_parts.first
  end

  def display_category
    category.presence || "Uncategorized"
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
