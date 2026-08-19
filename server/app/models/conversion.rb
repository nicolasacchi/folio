class Conversion < ApplicationRecord
  STATUSES = %w[pending running completed failed].freeze

  # "calibre" is a normal ebook-convert format conversion (source format !=
  # target_format). "ocr" is a Library::Ocr run over a scanned PDF, which
  # is pdf -> pdf (a text-layer companion, not a new format) — see
  # #target_differs_from_source and OcrBookJob. "text" is a
  # Library::TextCompanion build (pdf -> a plain-text reflow + its Kindle
  # AZW3, both companions of the source row rather than new book_files
  # rows) — see TextCompanionJob.
  KINDS = %w[calibre ocr text].freeze

  # Targets Calibre can produce without extra plugins. KFX is input-only.
  TARGET_FORMATS = %w[epub azw3 mobi pdf txt docx].freeze

  # Richest formats first: converting from these loses the least. Shared by
  # ConversionsController (explicit user-picked target), ReaderController
  # (auto-queued epub conversion when a book has no browser-readable file),
  # and EnsureKindleFormatJob (filtered down to non-Kindle-native formats —
  # see CONVERSION_SOURCE_PREFERENCE there).
  SOURCE_PREFERENCE = %w[epub azw3 kfx mobi azw fb2 docx html htmlz odt rtf lit pdf cbz cbr djvu txt].freeze

  # A conversion realistically finishes in minutes. A "running" row older
  # than this almost certainly means its worker crashed or was killed
  # mid-job — left alone it would wedge EnsureKindleFormatJob's active-scope
  # guard on that book forever. See Conversion.sweep_stuck!.
  STUCK_AFTER = 1.hour

  belongs_to :book
  belongs_to :book_file # source file

  validates :target_format, inclusion: { in: TARGET_FORMATS }
  validates :status, inclusion: { in: STATUSES }
  validates :kind, inclusion: { in: KINDS }
  validate :target_differs_from_source

  scope :active, -> { where(status: %w[pending running]) }

  # The book page follows conversion progress live.
  broadcasts_refreshes_to :book

  STATUSES.each do |name|
    define_method("#{name}?") { status == name }
  end

  def ocr?
    kind == "ocr"
  end

  def text?
    kind == "text"
  end

  # Marks running conversions whose worker appears to have died as failed,
  # dropping them out of `active` scope so EnsureKindleFormatJob (and
  # ConversionsController) can retry them. A nil started_at — set only by
  # mark_running! — means the row is stuck too (crashed before it could even
  # stamp one). Returns the number of conversions swept.
  def self.sweep_stuck!(older_than: STUCK_AFTER)
    cutoff = Time.current - older_than
    swept = 0
    where(status: "running").where("started_at IS NULL OR started_at < ?", cutoff).find_each do |conversion|
      conversion.mark_failed!("conversion timed out (worker stopped)")
      swept += 1
    end
    swept
  end

  def mark_running!
    update!(status: "running", started_at: Time.current, error: nil)
  end

  def mark_completed!
    update!(status: "completed", finished_at: Time.current)
  end

  def mark_failed!(message)
    update!(status: "failed", finished_at: Time.current, error: message.to_s.byteslice(0, 4000))
  end

  private

  def target_differs_from_source
    return unless book_file
    return if ocr? # an OCR run is pdf -> pdf, a companion, not a new format
    errors.add(:target_format, "matches the source format") if target_format == book_file.format
  end
end
