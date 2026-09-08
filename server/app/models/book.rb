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
  has_many :vocab_entries, dependent: :nullify

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

  # A newly ingested book (background upload, scan discovery) refreshes any
  # open library index in place — books/index.html.erb subscribes via
  # turbo_stream_from "books", and the layout morphs (turbo_refreshes_with
  # method: :morph), so a background import just appears on the shelf.
  # Create-only on purpose: a rescan updates thousands of existing rows,
  # and per-update refreshes would flood Solid Queue with refresh jobs that
  # change nothing the reader is looking at.
  after_create_commit { broadcast_refresh_to "books" }

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

  # The scanned PDF an OCR run (Library::Ocr / OcrBookJob) would work
  # from, or nil when there's nothing eligible — used by
  # ConversionsController's kind=ocr guard and the (later) OCR button.
  def ocr_candidate_file
    file = file_for("pdf")
    file if file&.available?
  end

  # The pdf book_file a "text only" companion (see Library::TextCompanion,
  # TextCompanionJob) can be built from — gated on it being the book's
  # actual Kindle-delivery file (see KINDLE_FORMATS): a richer format
  # already reflows on its own, so the text variant only matters for a
  # scanned pdf. Used by BooksController's build_text action, the (later)
  # UI gating, and DeliveriesController's variant=text handling.
  def text_companion_source_file
    file = kindle_file
    file if file&.format == "pdf"
  end

  # Queues Library::TextCompanion's build for this book (see
  # TextCompanionJob), mirroring ConversionsController#create_ocr's
  # shape/guards: a no-op when there's no eligible pdf or a build is
  # already active — returns nil for the former, the (existing or freshly
  # queued) Conversion otherwise. engine: "layer" (the default, fast
  # pdftotext-off-the-text-layer path) also no-ops once the text variant is
  # already usable — nothing to do. engine: "deep" deliberately SKIPS that
  # usable check: it's the point of the deep-OCR rebuild button (see
  # BooksController#build_text) that it *replaces* an already-usable
  # companion someone found wrong, not just fills a gap — but every other
  # guard still applies, including "don't queue a second build" below.
  #
  # The active-conversion guard is scoped by target_format, not kind:
  # index_conversions_on_active_book_target is UNIQUE(book_id,
  # target_format) across every kind, and the pre-existing "Convert to"
  # button (ConversionsController#create) can queue a plain kind:"calibre"
  # target_format:"txt" conversion for this same book_file. Scoping by
  # kind alone would miss that row and crash create! with
  # ActiveRecord::RecordNotUnique; rescuing it too is defense in depth
  # against the inherent check-then-insert race.
  def queue_text_companion!(engine: "layer")
    source = text_companion_source_file
    return nil unless source
    return nil if engine != "deep" && source.text_kindle_usable?

    active = conversions.active.find_by(target_format: "txt")
    return active if active

    conversion = conversions.create!(book_file: source, target_format: "txt", kind: "text")
    TextCompanionJob.perform_later(conversion.id, engine)
    conversion
  rescue ActiveRecord::RecordNotUnique
    conversions.active.find_by(target_format: "txt")
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

  # Unified "Keep reading" rail: merge the signed-in user's unfinished web
  # ReaderPositions with household Kindle currently_reading, dedupe by book
  # (most recent activity wins), cap at limit. Returns [[book, entry], ...]
  # where entry responds to progress_percent / activity_at / source_label.
  KeepReadingEntry = Struct.new(:progress_percent, :activity_at, :source_label, keyword_init: true)

  def self.keep_reading_for(user, limit: 10)
    by_book = {}

    currently_reading(limit: limit * 2).each do |book, state|
      by_book[book.id] = {
        book: book,
        at: state.content_mtime,
        entry: KeepReadingEntry.new(
          progress_percent: state.progress_percent,
          activity_at: state.content_mtime,
          source_label: state.device.name
        )
      }
    end

    if user
      user.reader_positions.includes(book: :book_files)
        .where("percent IS NULL OR percent <= ?", READING_FINISHED_THRESHOLD)
        .order(updated_at: :desc)
        .limit(limit * 2)
        .each do |pos|
          existing = by_book[pos.book_id]
          next if existing && existing[:at] >= pos.updated_at

          by_book[pos.book_id] = {
            book: pos.book,
            at: pos.updated_at,
            entry: KeepReadingEntry.new(
              progress_percent: pos.percent,
              activity_at: pos.updated_at,
              source_label: "Web"
            )
          }
        end
    end

    by_book.values
      .sort_by { |row| row[:at] }
      .reverse
      .first(limit)
      .map { |row| [ row[:book], row[:entry] ] }
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
