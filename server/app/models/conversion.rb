class Conversion < ApplicationRecord
  STATUSES = %w[pending running completed failed].freeze

  # Targets Calibre can produce without extra plugins. KFX is input-only.
  TARGET_FORMATS = %w[epub azw3 mobi pdf txt docx].freeze

  # Richest formats first: converting from these loses the least. Shared by
  # ConversionsController (explicit user-picked target), ReaderController
  # (auto-queued epub conversion when a book has no browser-readable file),
  # and EnsureKindleFormatJob (filtered down to non-Kindle-native formats —
  # see CONVERSION_SOURCE_PREFERENCE there).
  SOURCE_PREFERENCE = %w[epub azw3 kfx mobi azw fb2 docx html htmlz odt rtf lit pdf cbz cbr djvu txt].freeze

  belongs_to :book
  belongs_to :book_file # source file

  validates :target_format, inclusion: { in: TARGET_FORMATS }
  validates :status, inclusion: { in: STATUSES }
  validate :target_differs_from_source

  scope :active, -> { where(status: %w[pending running]) }

  # The book page follows conversion progress live.
  broadcasts_refreshes_to :book

  STATUSES.each do |name|
    define_method("#{name}?") { status == name }
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
    errors.add(:target_format, "matches the source format") if target_format == book_file.format
  end
end
