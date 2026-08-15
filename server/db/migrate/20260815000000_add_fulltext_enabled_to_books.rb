class AddFulltextEnabledToBooks < ActiveRecord::Migration[8.1]
  def change
    # No backfill: every existing book starts opted out. Fulltext indexing
    # used to run for the whole catalog and the search DB hit 20 GB, with
    # writes hanging the single-threaded indexing worker — the user now
    # hand-picks what goes in the index instead.
    add_column :books, :fulltext_enabled, :boolean, null: false, default: false
    add_index :books, :fulltext_enabled
  end
end
