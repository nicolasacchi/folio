class Device < ApplicationRecord
  has_many :reading_states, dependent: :destroy
  has_many :deliveries, dependent: :destroy
  has_many :queued_books, through: :deliveries, source: :book
  has_many :device_syncs, dependent: :destroy
  has_many :annotations, dependent: :destroy

  before_validation :assign_token, on: :create

  validates :name, presence: true, uniqueness: true
  validates :token, presence: true, uniqueness: true
  validates :low_space_threshold_mb, numericality: { greater_than: 0 }

  broadcasts_refreshes_to ->(_device) { "devices" }

  def touch_last_seen!
    # Avoid a write on every API call.
    update_column(:last_seen_at, Time.current) if last_seen_at.nil? || last_seen_at < 1.minute.ago
  rescue ActiveRecord::StatementTimeout
    # Telemetry only — never fail a request because this write was locked out.
  end

  def storage_known? = free_bytes.present? && total_bytes.present? && total_bytes.positive?

  def used_bytes
    storage_known? ? total_bytes - free_bytes : nil
  end

  def free_percent
    storage_known? ? (free_bytes * 100.0 / total_bytes) : nil
  end

  def low_space_threshold_bytes
    low_space_threshold_mb.to_i * 1024 * 1024
  end

  def low_space?
    storage_known? && free_bytes < low_space_threshold_bytes
  end

  # Bytes the pending queue will consume once downloaded.
  def pending_bytes
    deliveries.pending.includes(book: :book_files).sum { |d| d.book.kindle_file&.size.to_i }
  end

  def eviction_plan
    Library::EvictionPlanner.new(self).plan
  end

  # The reader/experiment policy the manifest carries to the daemon, which
  # pins the modern (KPP) reader and freezes Amazon's weblab experiments
  # on-device. See docs/kindle-519-kpp-reader-routing.html.
  def manifest_settings
    { modern_reader: modern_reader_pinned, freeze_experiments: freeze_experiments }
  end

  # Does what the daemon last reported match the policy we asked for? Drives
  # the "pending / applied" badge on the device page. When the reader is
  # pinned, "kpp_pending" still counts as applied — the marker is in place;
  # we're only waiting on Amazon's format-migration weblab (out of our hands).
  def reader_settings_applied?
    return false if reader_settings_applied_at.nil?

    reader_applied =
      if modern_reader_pinned
        reader_mode.in?(%w[kpp kpp_pending])
      else
        reader_mode == "legacy"
      end
    reader_applied && experiments_frozen == freeze_experiments
  end

  # Human summary of what a book actually opens in on the device.
  def reader_mode_label
    case reader_mode
    when "kpp"         then "modern reader active"
    when "kpp_pending" then "modern reader pinned — waiting on Amazon's format-migration rollout"
    when "legacy"      then "legacy reader (no back/home buttons)"
    else "not yet reported"
    end
  end

  # A cheap monotonic-enough fingerprint of "would a sync do anything?":
  # the newest change across this device's deliveries, the files of its
  # queued books (preparation bumps them), and those books' reading
  # states (another device's progress). The daemon compares it between
  # full syncs to get near-realtime pickup without full manifest polls.
  def queue_version
    book_ids = deliveries.active.select(:book_id)
    [
      deliveries.maximum(:updated_at),
      BookFile.where(book_id: book_ids).maximum(:updated_at),
      ReadingState.where(book_id: book_ids).maximum(:updated_at)
    ].compact.max.to_i
  end

  private

  def assign_token
    self.token ||= SecureRandom.hex(20)
  end
end
