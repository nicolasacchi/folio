class CreateDeviceSyncs < ActiveRecord::Migration[8.1]
  def change
    # One row per daemon sync pass (reported with the device status), so the
    # device page can show a sync history.
    create_table :device_syncs do |t|
      t.references :device, null: false, foreign_key: true
      t.integer :downloaded_count, null: false, default: 0
      t.integer :sdr_pushed_count, null: false, default: 0
      t.integer :sdr_applied_count, null: false, default: 0
      t.integer :removed_count, null: false, default: 0
      t.integer :error_count, null: false, default: 0
      t.integer :duration_ms
      t.bigint :free_bytes
      t.integer :battery_percent
      t.datetime :created_at, null: false
    end
    add_index :device_syncs, [ :device_id, :created_at ]
  end
end
