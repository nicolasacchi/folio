class CreateReadingStates < ActiveRecord::Migration[8.1]
  def change
    create_table :reading_states do |t|
      t.references :book, null: false, foreign_key: true
      t.references :device, null: false, foreign_key: true
      t.string :path, null: false
      t.datetime :content_mtime, null: false
      t.integer :size, null: false
      t.string :sha256, null: false

      t.timestamps
    end
    add_index :reading_states, [:book_id, :device_id], unique: true
  end
end
