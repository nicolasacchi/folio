class AddOcrDeliveryToBookFiles < ActiveRecord::Migration[8.1]
  def change
    change_table :book_files, bulk: true do |t|
      # The OCR text-layer companion produced by Library::Ocr (ocrmypdf) for
      # a scanned, image-only PDF. The original file is never modified —
      # this mirrors prepared_path/prepared_sha256/prepared_size below:
      # BookFile#ocr_fresh? / #read_source_path pick this up for fulltext
      # extraction and (eventually) reading, while the Kindle delivery path
      # (prepared_path/absolute_path) stays untouched.
      t.string :ocr_path
      t.string :ocr_sha256
      t.integer :ocr_size
      # sha256 of the source file the OCR companion was made from — a
      # mismatch means the source changed and the companion is stale.
      t.string :ocr_source_sha256
    end
  end
end
