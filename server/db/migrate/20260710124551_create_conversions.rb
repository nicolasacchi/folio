class CreateConversions < ActiveRecord::Migration[8.1]
  def change
    create_table :conversions do |t|
      t.references :book, null: false, foreign_key: true
      t.references :book_file, null: false, foreign_key: true
      t.string :target_format, null: false
      t.string :status, null: false, default: "pending"
      t.text :error
      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps
    end
  end
end
