class AddReaderPreferencesToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :reader_preferences, :text, default: "{}", null: false
  end
end
