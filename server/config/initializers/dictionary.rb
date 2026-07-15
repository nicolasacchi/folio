# The word-lookup dictionary is a plain SQLite file (storage/<env>_dictionary.sqlite3),
# not part of the primary database — see app/models/dictionary.rb.

Rails.application.config.after_initialize do
  Dictionary.ensure_schema!
rescue SQLite3::Exception
  # Storage not writable yet (e.g. during image build).
end
