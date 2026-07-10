# One row per file path the library scanner has processed. Doubles as the
# rescan skip-list (size+mtime unchanged => don't re-hash) and as durable
# memory: a book deleted in the UI stays deleted on the next scan because
# its path is still recorded here.
class ImportFile < ApplicationRecord
  STATUSES = %w[imported duplicate skipped failed missing removed].freeze

  belongs_to :book_file, optional: true

  validates :path, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  scope :problems, -> { where(status: %w[failed missing]) }
end
