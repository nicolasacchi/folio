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

  private

  def assign_token
    self.token ||= SecureRandom.hex(20)
  end
end
