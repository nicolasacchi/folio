class CreateAnnotations < ActiveRecord::Migration[8.1]
  def change
    # Highlights, notes and bookmarks parsed from a device's
    # "My Clippings.txt". Entries that can't be matched to a catalog book
    # keep book_id nil and are retried on later imports.
    create_table :annotations do |t|
      t.references :book, foreign_key: true
      t.references :device, null: false, foreign_key: true
      t.string :kind, null: false, default: "highlight"
      t.string :raw_title, null: false
      t.string :raw_author
      t.integer :location_start
      t.integer :location_end
      t.integer :page
      t.datetime :added_at
      t.text :content
      # SHA-256 of the raw entry; dedupes re-imports of the whole file.
      t.string :fingerprint, null: false
      t.timestamps
    end
    add_index :annotations, [ :device_id, :fingerprint ], unique: true
    add_index :annotations, [ :book_id, :added_at ]
    add_index :annotations, :kind
  end
end
