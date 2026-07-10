class CreateBookSearchIndex < ActiveRecord::Migration[8.1]
  def up
    execute BookSearch::SCHEMA_SQL
  end

  def down
    execute "DROP TABLE IF EXISTS book_search;"
  end
end
