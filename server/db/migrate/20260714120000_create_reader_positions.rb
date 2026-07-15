class CreateReaderPositions < ActiveRecord::Migration[8.1]
  def change
    # One row per (book, user): where the web reader last left off. Separate
    # from reading_states, which tracks per-device .sdr sync state parsed
    # off the Kindle — this is the browser reader's own progress.
    create_table :reader_positions do |t|
      t.references :book, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.text :cfi
      t.float :fraction
      t.float :percent
      # JSON blob of renderer-specific locating context (e.g. chapter index).
      t.text :context

      t.timestamps
    end
    add_index :reader_positions, [ :book_id, :user_id ], unique: true
  end
end
