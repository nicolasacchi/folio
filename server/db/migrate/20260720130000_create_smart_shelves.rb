class CreateSmartShelves < ActiveRecord::Migration[8.1]
  def change
    # Saved, named rule sets that resolve to a live Book scope (see
    # SmartShelf#books) — e.g. "Sci-fi by Asimov" or "Unread from 2023".
    # `rules` is a whitelisted {match, conditions} structure serialized as
    # JSON text (see SmartShelf::FIELDS for the field/operator whitelist);
    # it is never used to build raw SQL.
    create_table :smart_shelves do |t|
      t.string :name, null: false
      t.text :rules, null: false, default: "{}"
      # No DB-level default on purpose: 0 is truthy in Ruby, so a default
      # of 0 here would make SmartShelf#assign_position's `||=` a no-op
      # and every shelf would land on position 0. #assign_position always
      # sets a concrete value before insert, so the column never actually
      # sees NULL despite `null: false`.
      t.integer :position, null: false

      t.timestamps
    end
    add_index :smart_shelves, :name, unique: true
    add_index :smart_shelves, :position
  end
end
