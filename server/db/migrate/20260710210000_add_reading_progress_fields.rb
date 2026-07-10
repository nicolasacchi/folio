class AddReadingProgressFields < ActiveRecord::Migration[8.1]
  def change
    # Best-effort signals parsed out of the synced .sdr bundle so the web
    # UI can show reading activity without unpacking tarballs per request.
    change_table :reading_states, bulk: true do |t|
      t.integer :last_position
      t.integer :annotation_count, null: false, default: 0
      t.float :progress_percent
      t.string :progress_source
      t.text :sidecar_files
      t.datetime :parsed_at
    end
  end
end
