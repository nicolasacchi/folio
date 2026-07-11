class CreateDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :deliveries do |t|
      t.references :book, null: false, foreign_key: true
      t.references :device, null: false, foreign_key: true
      t.datetime :delivered_at

      t.timestamps
    end
    add_index :deliveries, [ :book_id, :device_id ], unique: true
  end
end
