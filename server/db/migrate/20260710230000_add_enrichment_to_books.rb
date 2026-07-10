class AddEnrichmentToBooks < ActiveRecord::Migration[8.1]
  def change
    change_table :books, bulk: true do |t|
      t.datetime :enriched_at
      t.string :enrichment_source
    end
  end
end
