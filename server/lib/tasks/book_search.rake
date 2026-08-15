namespace :book_search do
  desc "Move FTS rows from the primary database into the dedicated search database"
  task migrate: :environment do
    moved = BookSearch.migrate_from_primary!
    puts "moved #{moved} rows into #{BookSearch.db_path}"
    puts "run VACUUM on the primary database when the queue is idle to reclaim space"
  end

  desc "Rewrite search rows for the whole catalog and requeue extraction for opted-in books still missing it (run after truncating the search DB; safe to re-run otherwise)"
  task rebuild_metadata: :environment do
    written = 0
    queued = 0
    Book.find_each do |book|
      # Synchronous: a metadata-only FTS insert is milliseconds. fulltext:
      # nil falls back to whatever is already stored — on a freshly
      # truncated DB that's nothing, so this also resets has_fulltext to
      # false for every book, putting opted-in ones into the honest
      # "indexing pending" UI state instead of a stale has_fulltext=true
      # with no row behind it. On a non-truncated DB the fallback preserves
      # any stored fulltext, making this task idempotent.
      BookSearch.index_book!(book, fulltext: nil)
      written += 1

      # has_fulltext was just rewritten via update_all, which does not
      # touch this in-memory instance — reload to see whether the row
      # index_book! wrote actually has extracted text (only possible on a
      # non-truncated DB) or came back empty and needs (re)extraction.
      if book.fulltext_enabled? && !book.reload.has_fulltext?
        IndexBookJob.perform_later(book.id)
        queued += 1
      end

      puts "#{written} books processed…" if (written % 1000).zero?
    end
    puts "done: #{written} metadata rows written, #{queued} opted-in books queued for extraction"
  end
end
