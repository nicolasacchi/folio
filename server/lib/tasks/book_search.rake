namespace :book_search do
  desc "Move FTS rows from the primary database into the dedicated search database"
  task migrate: :environment do
    moved = BookSearch.migrate_from_primary!
    puts "moved #{moved} rows into #{BookSearch.db_path}"
    puts "run VACUUM on the primary database when the queue is idle to reclaim space"
  end
end
