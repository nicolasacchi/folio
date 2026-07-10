class AddLibraryScanning < ActiveRecord::Migration[8.1]
  def change
    # Ledger of every file the folder scanner has looked at, so rescans can
    # skip unchanged paths without re-hashing tens of gigabytes.
    create_table :import_files do |t|
      t.string :path, null: false
      t.bigint :size, null: false
      t.datetime :mtime, null: false
      t.string :sha256
      t.string :status, null: false, default: "imported"
      t.string :message
      t.belongs_to :book_file, null: true, foreign_key: { on_delete: :nullify }
      t.timestamps
    end
    add_index :import_files, :path, unique: true
    add_index :import_files, :sha256
    add_index :import_files, :status

    # Scanned files live outside the app's storage; when one disappears the
    # book stays but the file is flagged instead of served.
    add_column :book_files, :available, :boolean, null: false, default: true

    # Browse/sort/filter over a five-figure library.
    add_index :books, :title
    add_index :books, :author
    add_index :books, :series
    add_index :books, :created_at
  end
end
