class AddKindAndReaderWritebackToDevices < ActiveRecord::Migration[8.1]
  def change
    # "kindle" = a physical device synced via the daemon API; "web" = the
    # synthetic Device.web_reader! row that owns annotations/reading_states
    # created by the in-browser reader.
    add_column :devices, :kind, :string, null: false, default: "kindle"
    add_index :devices, :kind
    add_column :devices, :reader_writeback, :boolean, null: false, default: false
  end
end
