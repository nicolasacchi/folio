class BookFile < ApplicationRecord
  # Everything Calibre can reasonably take as conversion input and that is
  # worth keeping in a private library.
  FORMATS = %w[epub azw3 azw mobi prc kfx pdf txt cbz cbr djvu docx fb2 html htmlz lit odt rtf].freeze
  SOURCES = %w[upload converted scan].freeze

  belongs_to :book
  # Book already cascades to conversions, but that only fires when the
  # whole book is destroyed — a book_file destroyed on its own (single
  # missing/pruned file, book survives) needs its own cascade or the FK
  # (conversions.book_file_id, NOT NULL, no ON DELETE) raises.
  has_many :conversions, dependent: :destroy

  validates :format, presence: true, inclusion: { in: FORMATS }, uniqueness: { scope: :book_id }
  validates :path, presence: true, uniqueness: true
  validates :sha256, presence: true
  validates :size, presence: true
  validates :source, inclusion: { in: SOURCES }

  after_destroy :remove_from_disk
  after_destroy :remember_removal

  scope :available, -> { where(available: true) }

  # New formats appear on the book page as soon as a conversion lands.
  broadcasts_refreshes_to :book

  # Scanned files are referenced in place (absolute path, e.g. under the
  # read-only library share) instead of copied into Library.root.
  def external?
    path.start_with?("/")
  end

  def absolute_path
    external? ? Pathname.new(path) : Library.root.join(path)
  end

  def filename
    File.basename(path)
  end

  def kindle_ready?
    Book::KINDLE_FORMATS.include?(format)
  end

  # The Kindle catalog identity (EXTH ASIN + cdeType) baked into MOBI/AZW3
  # files. The firmware names its cover-thumbnail cache entries after these,
  # so the manifest needs them to ship covers the Library UI will display.
  # Parsed once per file (rows are immutable after ingest).
  def cde_identity
    if cde_parsed_at.nil?
      identity = Library::MobiCde.parse(delivery_path)
      update_columns(asin: identity[:asin], cde_type: identity[:cde_type], cde_parsed_at: Time.current)
    end
    { asin: asin, cde_type: cde_type }
  end

  # What actually goes to the Kindle: the prepared copy (store identity
  # neutralized + cover embedded, see Library::KindlePrep) when current,
  # else the raw file.
  def prepared_fresh?
    prepared_path.present? && prepared_source_sha256 == sha256 &&
      File.exist?(prepared_absolute_path)
  end

  def prepared_absolute_path
    Library.base_root.join(prepared_path)
  end

  def needs_preparation?
    Library::KindlePrep.preparable?(self) && !prepared_fresh?
  end

  def delivery_path
    prepared_fresh? ? prepared_absolute_path : absolute_path
  end

  def delivery_sha256
    prepared_fresh? ? prepared_sha256 : sha256
  end

  def delivery_size
    prepared_fresh? ? prepared_size : size
  end

  # Preparation may change the container (azw3 → joint mobi), so the
  # delivered name/format follow the prepared file, keeping the human
  # "Title -- Author" stem.
  def delivery_format
    prepared_fresh? ? File.extname(prepared_path).delete_prefix(".").presence || format : format
  end

  def delivery_filename
    "#{File.basename(filename, '.*')}.#{delivery_format}"
  end

  private

  # Never touch external files: the scan roots are someone else's data
  # (and mounted read-only in production). The prepared delivery copy
  # (see Library::KindlePrep) is always a local, regenerable file — even
  # for an external source — so it's removed unconditionally; the whole
  # point of this hook is that a lone book_file destroy (book survives)
  # doesn't leave that copy orphaned under storage/prepared.
  def remove_from_disk
    FileUtils.rm_f(absolute_path) unless external?
    FileUtils.rm_f(prepared_absolute_path) if prepared_path.present?
  end

  # Keeping the ledger row (as "removed") means the next scan will not
  # resurrect a book the user deliberately deleted.
  def remember_removal
    ImportFile.where(path: path).update_all(status: "removed", book_file_id: nil) if external?
  end
end
