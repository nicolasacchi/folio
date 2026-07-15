# Where a user last left off in the in-browser reader for a given book.
# One row per (book, user) — distinct from ReadingState, which tracks
# per-device .sdr sync state parsed off a physical Kindle.
class ReaderPosition < ApplicationRecord
  belongs_to :book
  belongs_to :user

  # Renderer-specific extras (e.g. the foliate-js TOC item at the saved
  # position) — opaque to the server, just round-tripped for the client.
  serialize :context, coder: JSON

  validates :user_id, uniqueness: { scope: :book_id }
end
