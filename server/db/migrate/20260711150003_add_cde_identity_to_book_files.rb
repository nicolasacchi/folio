class AddCdeIdentityToBookFiles < ActiveRecord::Migration[8.1]
  def change
    change_table :book_files, bulk: true do |t|
      # The Kindle catalog identity embedded in the file's EXTH header
      # (record 113/504 = ASIN, 501 = cdeType). Parsed lazily; the firmware
      # derives its thumbnail-cache filename from these, so the manifest
      # needs them to deliver covers that the Library UI will actually show.
      t.string :asin
      t.string :cde_type
      t.datetime :cde_parsed_at
    end
  end
end
