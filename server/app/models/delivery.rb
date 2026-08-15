# A book queued for a specific device. The device manifest only lists
# queued books — with a multi-thousand-book library the Kindle can't
# (and shouldn't) mirror everything, so "Send to Kindle" is an explicit
# act, like Amazon's own delivery model. `delivered_at` flips when the
# device actually downloads the file.
#
# Removal mirrors delivery: `evict_requested_at` puts the book in the
# manifest's `removals` list, the daemon deletes the file and acks, and
# `removed_at` closes the loop (the row stays as on-device history).
#
# `raw` is this device's per-delivery variant choice (see
# BookFile#delivery_path) — true bypasses the OCR companion for a book
# whose scan has one, so this one device gets the untouched original
# instead. Changing it needs no extra plumbing: the manifest recomputes
# delivery_sha256 with it on every poll, so a sha change alone triggers a
# re-fetch (see DeliveriesController#create).
class Delivery < ApplicationRecord
  belongs_to :book
  belongs_to :device

  validates :book_id, uniqueness: { scope: :device_id }

  # Queue and on-device state ignores rows already removed from the device.
  scope :active, -> { where(removed_at: nil) }
  scope :pending, -> { active.where(delivered_at: nil, evict_requested_at: nil) }
  scope :delivered, -> { active.where.not(delivered_at: nil) }
  scope :on_device, -> { delivered.where(evict_requested_at: nil) }
  scope :evict_requested, -> { active.where.not(evict_requested_at: nil) }
  scope :removed, -> { where.not(removed_at: nil) }

  # Queue/device pages morph-refresh whenever any delivery changes state;
  # the book page's send/remove buttons follow along.
  broadcasts_refreshes_to ->(_delivery) { "deliveries" }
  broadcasts_refreshes_to :book

  def delivered? = delivered_at.present?
  def evict_requested? = evict_requested_at.present?
  def removed? = removed_at.present?

  def status
    return "removed" if removed?
    return "removing" if evict_requested?
    return "on device" if delivered?
    "queued"
  end

  def request_eviction!(reason)
    update!(evict_requested_at: Time.current, evict_reason: reason)
  end

  def cancel_eviction!
    update!(evict_requested_at: nil, evict_reason: nil)
  end

  def mark_removed!
    update!(removed_at: Time.current)
  end

  # "Send to Kindle" on a book that was previously removed re-arms the row.
  def reactivate!
    update!(delivered_at: nil, evict_requested_at: nil, evict_reason: nil, removed_at: nil)
  end
end
