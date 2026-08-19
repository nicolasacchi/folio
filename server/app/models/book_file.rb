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
  # neutralized + cover embedded, see Library::KindlePrep) when current;
  # else the OCR'd companion (#ocr_fresh?) when current; else the raw
  # file. Prepared must win when both exist — it's the copy with the
  # Kindle store identity patched in — but the two never actually compete
  # today: PATCHABLE_FORMATS excludes pdf, and OCR only ever applies to
  # pdf rows.
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

  # variant: is the per-Delivery choice (see Delivery::VARIANTS,
  # Delivery#variant): "auto" is the historical default precedence
  # (prepared > OCR companion > raw); "original" skips the ocr_fresh?
  # branch only (today's old raw:true); "text" prefers the text-companion
  # AZW3 (see Library::TextCompanion, TextCompanionJob) when it's usable,
  # else falls all the way back through the "auto" chain — a device asking
  # for the text variant should get *something* immediately (the pdf),
  # then re-deliver once the AZW3 build lands (its sha changes). Prepared
  # precedence stays first for "auto"/"original" regardless of either:
  # PATCHABLE_FORMATS excludes pdf and OCR only ever applies to pdf rows,
  # so prepared and OCR never actually compete.
  def delivery_path(variant: "auto")
    case variant
    when "text"
      text_kindle_usable? ? text_kindle_absolute_path : delivery_path(variant: "auto")
    when "original"
      prepared_fresh? ? prepared_absolute_path : absolute_path
    else
      if prepared_fresh?
        prepared_absolute_path
      elsif ocr_fresh?
        ocr_absolute_path
      else
        absolute_path
      end
    end
  end

  def delivery_sha256(variant: "auto")
    case variant
    when "text"
      text_kindle_usable? ? text_kindle_sha256 : delivery_sha256(variant: "auto")
    when "original"
      prepared_fresh? ? prepared_sha256 : sha256
    else
      if prepared_fresh?
        prepared_sha256
      elsif ocr_fresh?
        ocr_sha256
      else
        sha256
      end
    end
  end

  def delivery_size(variant: "auto")
    case variant
    when "text"
      text_kindle_usable? ? text_kindle_size : delivery_size(variant: "auto")
    when "original"
      prepared_fresh? ? prepared_size : size
    else
      if prepared_fresh?
        prepared_size
      elsif ocr_fresh?
        ocr_size
      else
        size
      end
    end
  end

  # Preparation (azw3 → joint mobi) or a text-companion AZW3 build may
  # change the container, so the delivered format follows whichever file
  # actually gets served in each of those two cases; every other case
  # (including "auto" falling back to the OCR companion, which is still a
  # pdf) keeps the book_file's own #format.
  def delivery_format(variant: "auto")
    if variant == "text" && text_kindle_usable?
      File.extname(text_kindle_path).delete_prefix(".").presence || format
    elsif prepared_fresh?
      File.extname(prepared_path).delete_prefix(".").presence || format
    else
      format
    end
  end

  def delivery_filename(variant: "auto")
    "#{File.basename(filename, '.*')}.#{delivery_format(variant: variant)}"
  end

  # The OCR text-layer companion (see Library::Ocr, OcrBookJob) is fresh
  # when it was made from the file's current bytes and still exists on
  # disk — mirrors #prepared_fresh?. Only ever true for pdf book_files;
  # other formats never get ocr_path populated. Feeds both reading
  # (#read_source_path) and Kindle delivery (#delivery_path, see the
  # precedence note above #prepared_fresh?).
  def ocr_fresh?
    ocr_path.present? && ocr_source_sha256 == sha256 && File.exist?(ocr_absolute_path)
  end

  def ocr_absolute_path
    Library.base_root.join(ocr_path)
  end

  # What text extraction and the reader should read: the OCR'd companion
  # when it's fresh, else the raw file. Kept separate from #delivery_path
  # even though both now fall through to the same OCR companion — this one
  # never considers #prepared_fresh? (a Kindle-store-patched copy is never
  # what search/reading should read from).
  def read_source_path
    ocr_fresh? ? ocr_absolute_path : absolute_path
  end

  # The plain-text reflow companion (see Library::TextCompanion,
  # TextCompanionJob) is fresh when it was made from the file's current
  # content and still exists on disk — mirrors #ocr_fresh?/#prepared_fresh?.
  # Only ever true for pdf book_files (the only source TextCompanionJob
  # builds from).
  def text_fresh?
    text_path.present? && text_source_sha256 == text_source_content_sha256 && File.exist?(text_absolute_path)
  end

  def text_absolute_path
    Library.base_root.join(text_path)
  end

  # What #text_fresh? (and TextCompanionJob, when stamping a freshly-built
  # companion) compares text_source_sha256 against: the OCR companion's
  # sha when it's fresh, else the raw file's — so a re-OCR automatically
  # stales the text companion, the same way it stales anything else read
  # off #read_source_path.
  def text_source_content_sha256
    ocr_fresh? ? ocr_sha256 : sha256
  end

  # The Kindle-ready AZW3 built from the text companion (see
  # TextCompanionJob) is usable once the companion itself is fresh AND the
  # AZW3 build actually succeeded and is still on disk — the AZW3 half can
  # fail (or simply not have run yet) even when the plain-text companion
  # is fine.
  def text_kindle_usable?
    text_fresh? && text_kindle_path.present? && File.exist?(text_kindle_absolute_path)
  end

  def text_kindle_absolute_path
    Library.base_root.join(text_kindle_path)
  end

  private

  # Never touch external files: the scan roots are someone else's data
  # (and mounted read-only in production). The prepared delivery copy
  # (see Library::KindlePrep), the OCR companion (see Library::Ocr) and
  # the text companion + its AZW3 build (see Library::TextCompanion) are
  # always local, regenerable files — even for an external source — so
  # all are removed unconditionally; the whole point of this hook is that
  # a lone book_file destroy (book survives) doesn't leave them orphaned
  # under storage/prepared, storage/ocr or storage/text.
  def remove_from_disk
    FileUtils.rm_f(absolute_path) unless external?
    FileUtils.rm_f(prepared_absolute_path) if prepared_path.present?
    FileUtils.rm_f(ocr_absolute_path) if ocr_path.present?
    FileUtils.rm_f(text_absolute_path) if text_path.present?
    FileUtils.rm_f(text_kindle_absolute_path) if text_kindle_path.present?
  end

  # Keeping the ledger row (as "removed") means the next scan will not
  # resurrect a book the user deliberately deleted.
  def remember_removal
    ImportFile.where(path: path).update_all(status: "removed", book_file_id: nil) if external?
  end
end
