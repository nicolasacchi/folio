class AddCategoryToBooks < ActiveRecord::Migration[8.1]
  def change
    # "category" or "category/subcategory" derived from the scan path
    # (see Library::Category); never author/title segments.
    add_column :books, :category, :string
    add_index :books, :category
  end
end
