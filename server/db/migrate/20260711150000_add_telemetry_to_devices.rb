class AddTelemetryToDevices < ActiveRecord::Migration[8.1]
  def change
    change_table :devices, bulk: true do |t|
      # Reported by the daemon on every sync (POST /api/v1/device/status).
      t.bigint :free_bytes
      t.bigint :total_bytes
      t.integer :battery_percent
      t.string :firmware_version
      t.string :serial
      t.string :kindled_version
      t.datetime :status_reported_at
      t.datetime :last_sync_at

      # Storage policy, set from the device page.
      t.integer :low_space_threshold_mb, null: false, default: 500
      t.boolean :auto_evict, null: false, default: false
    end
  end
end
