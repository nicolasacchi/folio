class CreateBookFiles < ActiveRecord::Migration[8.1]
  def change
    create_table :book_files do |t|
      t.references :book, null: false, foreign_key: true
      t.string :format, null: false
      t.string :path, null: false
      t.integer :size, null: false
      t.string :sha256, null: false
      t.string :source, null: false, default: "upload"

      t.timestamps
    end
    add_index :book_files, :sha256
    add_index :book_files, :path, unique: true
    add_index :book_files, [:book_id, :format], unique: true
  end
end
