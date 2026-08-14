class AddKindToConversions < ActiveRecord::Migration[8.1]
  def change
    # Distinguishes a normal Calibre format conversion from an OCR run
    # (pdf -> pdf text-layer companion, see Library::Ocr / OcrBookJob).
    # Existing rows are all Calibre conversions.
    add_column :conversions, :kind, :string, null: false, default: "calibre"
  end
end
