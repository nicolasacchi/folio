class AddHasFulltextToBooks < ActiveRecord::Migration[8.1]
  def up
    add_column :books, :has_fulltext, :boolean, null: false, default: false
    add_index :books, :has_fulltext

    # One-time backfill from the FTS database (a separate SQLite file, so it
    # cannot be joined in SQL from here). BookSearch.book_ids_with_fulltext
    # does a full scan of the fulltext column, which is fine as a single
    # migrate-time cost but is exactly what we're taking off the hot path
    # (LibraryScansController#show) by adding this column.
    ids = BookSearch.book_ids_with_fulltext
    Book.where(id: ids).update_all(has_fulltext: true) if ids.any?
  end

  def down
    remove_index :books, :has_fulltext
    remove_column :books, :has_fulltext
  end
end
