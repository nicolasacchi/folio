class AddLifecycleToDeliveries < ActiveRecord::Migration[8.1]
  def change
    change_table :deliveries, bulk: true do |t|
      # Removal flow: the server marks a delivered book for eviction
      # (manually from the device page or automatically when space is low),
      # the manifest lists it under `removals`, the daemon deletes the file
      # and acks, which stamps `removed_at`.
      t.datetime :evict_requested_at
      t.string :evict_reason
      t.datetime :removed_at
    end
  end
end
