class AddReaderSettingsToDevices < ActiveRecord::Migration[8.0]
  def change
    # Policy the admin sets (rides the manifest to the daemon).
    add_column :devices, :modern_reader_pinned, :boolean, default: true, null: false
    add_column :devices, :freeze_experiments, :boolean, default: true, null: false

    # Observed state the daemon reports back after reconciling on-device.
    add_column :devices, :reader_mode, :string
    add_column :devices, :experiments_frozen, :boolean
    add_column :devices, :reader_settings_applied_at, :datetime
  end
end
