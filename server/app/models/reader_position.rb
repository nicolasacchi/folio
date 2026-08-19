# Where a user last left off in the in-browser reader for a given book.
# One row per (book, user, variant) — distinct from ReadingState, which
# tracks per-device .sdr sync state parsed off a physical Kindle.
#
# `variant` splits pagination that genuinely differs: "" covers ocr/raw/
# none (they all paginate identically), "text" is the separate text-only
# companion (see Library::TextCompanion) — a different underlying file
# with its own, incompatible cfis.
class ReaderPosition < ApplicationRecord
  VARIANTS = [ "", "text" ].freeze

  belongs_to :book
  belongs_to :user

  # Renderer-specific extras (e.g. the foliate-js TOC item at the saved
  # position) — opaque to the server, just round-tripped for the client.
  serialize :context, coder: JSON

  validates :variant, inclusion: { in: VARIANTS }
  validates :user_id, uniqueness: { scope: [ :book_id, :variant ] }
end
