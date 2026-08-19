class AddTextCompanionToBookFiles < ActiveRecord::Migration[8.1]
  def change
    change_table :book_files, bulk: true do |t|
      # The plain-text reflow companion (see Library::TextCompanion,
      # TextCompanionJob) — mirrors ocr_path/ocr_sha256/ocr_size/
      # ocr_source_sha256 above: a regenerable file tracked on this row,
      # not a new book_files row (a txt row would hijack readable_file/
      # kindle_file's format ranking). text_source_sha256 is compared
      # against the OCR companion's sha when one is fresh, else the raw
      # file's — so a re-OCR automatically stales this too (see
      # BookFile#text_fresh?).
      t.string :text_path
      t.string :text_sha256
      t.integer :text_size
      t.string :text_source_sha256
      # The Kindle-ready AZW3 Calibre builds from the text companion.
      # Tracked separately: the AZW3 build can fail (or lag) even when the
      # plain-text companion itself is fine, so text_fresh? and
      # text_kindle_usable? are deliberately independent checks.
      t.string :text_kindle_path
      t.string :text_kindle_sha256
      t.integer :text_kindle_size
    end
  end
end
