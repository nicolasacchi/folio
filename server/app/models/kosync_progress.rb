# One row per (kosync_credential, opaque document hash) — the kosync
# protocol's whole unit of sync. `document` is a client-chosen opaque
# digest (KOReader's partial-md5 of the file's bytes by default, or md5 of
# just the filename — see the "Document matching method" menu in
# main.lua); the server never opens a file, never recomputes it, and never
# maps it to a Folio Book — it's a plain, opaque key. `progress` is
# whatever string KOReader's navigator understands: an XPointer for
# reflowable formats, a page number for paged ones — never a foliate CFI
# (see ReaderPosition) and never the Kindle .sdr binary (see ReadingState).
#
# Every successful PUT unconditionally overwrites this row — no
# compare-and-swap, no per-device history — with `synced_at` stamped from
# the server's own clock, exactly like the reference server (its spec
# suite asserts a later PUT wins even when percentage regresses).
class KosyncProgress < ApplicationRecord
  belongs_to :kosync_credential

  # Optional client metadata (filename/title/authors) — the official
  # service ignores it entirely; Folio persists it only in case a future
  # admin UI wants to show "what is this document" next to a raw hash.
  serialize :metadata, coder: JSON

  validates :document, presence: true, format: { without: /:/, message: "must not contain ':'" },
    uniqueness: { scope: :kosync_credential_id }
  validates :progress, presence: true
  validates :percentage, presence: true, numericality: true
  validates :device, presence: true
end
