class AddRawToDeliveries < ActiveRecord::Migration[8.1]
  def change
    # Per-delivery variant choice: false sends whatever #delivery_path
    # already prefers (OCR companion when fresh), true bypasses the OCR
    # branch for that one device — see BookFile#delivery_path.
    add_column :deliveries, :raw, :boolean, null: false, default: false
  end
end
