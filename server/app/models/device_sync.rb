# One daemon sync pass, reported alongside the device status. Powers the
# sync-history timeline on the device page.
class DeviceSync < ApplicationRecord
  belongs_to :device

  scope :recent, -> { order(created_at: :desc) }

  broadcasts_refreshes_to ->(_sync) { "devices" }

  def activity?
    [ downloaded_count, sdr_pushed_count, sdr_applied_count, removed_count, error_count ].any?(&:positive?)
  end
end
