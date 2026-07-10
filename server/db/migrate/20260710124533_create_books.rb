class CreateBooks < ActiveRecord::Migration[8.1]
  def change
    create_table :books do |t|
      t.string :public_id, null: false
      t.string :title, null: false
      t.string :author
      t.string :series
      t.float :series_index
      t.string :language
      t.text :description
      t.integer :published_year

      t.timestamps
    end
    add_index :books, :public_id, unique: true
  end
end
