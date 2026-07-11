# The search index is an SQLite FTS5 virtual table in its own database
# file (storage/<env>_search.sqlite3). The dump exclusion stays because a
# legacy in-primary table may still exist until `book_search:migrate` has
# run.
ActiveRecord::SchemaDumper.ignore_tables = [/\Abook_search/]

Rails.application.config.after_initialize do
  BookSearch.ensure_schema!
rescue SQLite3::Exception
  # Storage not writable yet (e.g. during image build).
end
