class ReplaceRawWithVariantOnDeliveries < ActiveRecord::Migration[8.1]
  # Per-delivery variant choice, replacing the old boolean `raw` with a
  # 3-way string (see BookFile#delivery_path/#delivery_sha256/etc.):
  # "auto" = old raw:false (prefer the OCR companion when fresh), "original"
  # = old raw:true (bypass it), "text" = new — prefer the text-companion
  # AZW3, falling back to the "auto" chain when it isn't built yet.
  def up
    add_column :deliveries, :variant, :string, null: false, default: "auto"
    execute "UPDATE deliveries SET variant = 'original' WHERE raw = 1"
    remove_column :deliveries, :raw
  end

  def down
    add_column :deliveries, :raw, :boolean, null: false, default: false
    execute "UPDATE deliveries SET raw = 1 WHERE variant = 'original'"
    remove_column :deliveries, :variant
  end
end
