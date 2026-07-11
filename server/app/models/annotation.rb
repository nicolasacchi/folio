# A highlight, note or bookmark parsed from a device's "My Clippings.txt"
# (see Library::Clippings). Highlights carry the highlighted passage in
# +content+; notes carry the typed note; bookmarks have no content.
class Annotation < ApplicationRecord
  KINDS = %w[highlight note bookmark].freeze

  belongs_to :book, optional: true
  belongs_to :device

  validates :kind, inclusion: { in: KINDS }
  validates :raw_title, presence: true
  validates :fingerprint, presence: true, uniqueness: { scope: :device_id }

  scope :matched, -> { where.not(book_id: nil) }
  scope :unmatched, -> { where(book_id: nil) }
  scope :highlights, -> { where(kind: "highlight") }
  scope :notes, -> { where(kind: "note") }
  scope :with_content, -> { where.not(content: [ nil, "" ]) }
  scope :recent, -> { order(added_at: :desc, id: :desc) }

  def location_label
    return "page #{page}" if page.present? && location_start.blank?
    return nil if location_start.blank?
    range = location_end.present? && location_end != location_start ? "#{location_start}–#{location_end}" : location_start.to_s
    page.present? ? "page #{page} · loc. #{range}" : "loc. #{range}"
  end
end
