class AddPreparedDeliveryToBookFiles < ActiveRecord::Migration[8.1]
  def change
    change_table :book_files, bulk: true do |t|
      # The Kindle-delivery copy produced by Library::KindlePrep: EXTH
      # store-identity neutralized (so the firmware treats it as a personal
      # document and extracts the embedded cover itself) and a cover
      # embedded when the source lacked one. When present, the manifest and
      # the download endpoint serve this instead of the raw file.
      t.string :prepared_path
      t.string :prepared_sha256
      t.integer :prepared_size
      t.datetime :prepared_at
      # sha256 of the source file the prepared copy was made from — a
      # mismatch means the source changed and the copy is stale.
      t.string :prepared_source_sha256
    end
  end
end
