# The search index is an SQLite FTS5 virtual table. schema.rb cannot
# represent it, so its tables are excluded from the dump and the table is
# (re)created idempotently wherever the schema was loaded instead of migrated.
ActiveRecord::SchemaDumper.ignore_tables = [/\Abook_search/]

Rails.application.config.after_initialize do
  BookSearch.ensure_schema!
rescue ActiveRecord::ActiveRecordError, SQLite3::Exception
  # Database not created/loaded yet (e.g. during db:prepare boot).
end
