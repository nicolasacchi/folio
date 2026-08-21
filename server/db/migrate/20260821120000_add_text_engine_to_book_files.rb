class AddTextEngineToBookFiles < ActiveRecord::Migration[8.1]
  def change
    # Which extraction path built this row's current text companion (see
    # Library::TextCompanion, TextCompanionJob): "layer" is the default,
    # fast pdftotext-off-the-text-layer path every existing row was built
    # with; "deep" is the opt-in per-book rebuild that rasterizes the raw
    # scan and re-OCRs it with tesseract directly (see
    # Library::TextCompanion.deep_ocr_text). Stored on the row (not just
    # implied by the AZW3/txt bytes) so BookFile#text_source_content_sha256
    # knows which staleness rule to apply, and so the UI can tell the user
    # which flavor of text they're reading.
    add_column :book_files, :text_engine, :string, null: false, default: "layer"
  end
end
