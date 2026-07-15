class AddReaderFieldsToAnnotations < ActiveRecord::Migration[8.1]
  def change
    change_table :annotations, bulk: true do |t|
      # "clippings" = parsed from My Clippings.txt (existing flow); the web
      # reader writes "reader" annotations directly with a CFI instead of
      # location_start/location_end.
      t.string :source, null: false, default: "clippings"
      t.text :cfi
      t.string :color
      t.text :note
    end
  end
end
