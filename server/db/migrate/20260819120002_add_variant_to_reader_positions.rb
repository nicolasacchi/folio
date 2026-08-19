class AddVariantToReaderPositions < ActiveRecord::Migration[8.1]
  def change
    # Distinguishes a text-companion reading position from every other
    # variant (ocr/raw/none share identical pagination, so they share one
    # row) — see ReaderPosition, ReaderController. "" is the shared key.
    add_column :reader_positions, :variant, :string, null: false, default: ""
    remove_index :reader_positions, [ :book_id, :user_id ], unique: true
    add_index :reader_positions, [ :book_id, :user_id, :variant ], unique: true
  end
end
