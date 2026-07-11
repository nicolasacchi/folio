# A book queued for a specific device. The device manifest only lists
# queued books — with a multi-thousand-book library the Kindle can't
# (and shouldn't) mirror everything, so "Send to Kindle" is an explicit
# act, like Amazon's own delivery model. `delivered_at` flips when the
# device actually downloads the file.
class Delivery < ApplicationRecord
  belongs_to :book
  belongs_to :device

  validates :book_id, uniqueness: { scope: :device_id }

  scope :pending, -> { where(delivered_at: nil) }
  scope :delivered, -> { where.not(delivered_at: nil) }

  def delivered? = delivered_at.present?
end
