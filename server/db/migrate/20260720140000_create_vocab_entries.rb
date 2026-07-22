class CreateVocabEntries < ActiveRecord::Migration[8.1]
  def change
    # The "vocab notebook": one row per word a reader has looked up in the
    # in-browser dictionary (see LookupsController#show), captured by
    # VocabEntriesController#create. book_id is nullable — a lookup need
    # not happen from inside a book's reader session — but the reader
    # itself always sends one. (user, book, lemma, lang) is the dedupe
    # key: re-looking-up the same word in the same book refreshes the
    # existing row (context/gloss/updated_at) via VocabEntry.upsert_lookup
    # instead of piling up duplicates.
    create_table :vocab_entries do |t|
      t.references :user, null: false, foreign_key: true
      t.references :book, foreign_key: true
      t.string :word, null: false
      t.string :lemma, null: false
      t.string :lang, null: false
      # The surrounding sentence at lookup time, best-effort — nil when the
      # reader couldn't cleanly capture one (see reader_controller.js).
      t.text :context
      # Snapshot of the dictionary's first/best gloss at save time, so an
      # export is self-contained even if the offline dictionary changes.
      t.text :gloss

      t.timestamps
    end

    add_index :vocab_entries, [ :user_id, :book_id, :lemma, :lang ], unique: true,
      name: "index_vocab_entries_on_dedupe_key"
    add_index :vocab_entries, [ :user_id, :updated_at ]
    add_index :vocab_entries, [ :book_id, :updated_at ]
  end
end
