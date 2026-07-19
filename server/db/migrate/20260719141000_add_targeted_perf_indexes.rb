class AddTargetedPerfIndexes < ActiveRecord::Migration[8.1]
  def change
    # Api::V1::ManifestsController#show scopes every device's manifest with
    # `current_device.deliveries.active.where(evict_requested_at: nil)`
    # (~every 30s per device), and Api::V1::BaseController's per-book
    # download-auth lookup + DeviceStatusesController's active-delivery
    # sweep use the same shape. `index_deliveries_on_device_id` alone makes
    # SQLite seek to the device's rows, but "removed" deliveries (history —
    # unbounded over the life of a device) sit in that same range and have
    # to be scanned past on every poll. A partial index scoped to
    # removed_at IS NULL stays exactly as small as "currently active
    # deliveries for this device" forever, mirroring the existing partial
    # index on conversions' active-rows.
    add_index :deliveries, [ :device_id, :evict_requested_at ],
      where: "removed_at IS NULL",
      name: "index_deliveries_on_device_active"

    # ReadingController#index (`/reading`) runs
    # `ReadingState.order(content_mtime: :desc).limit(600)` over the whole
    # table with no supporting index — a full sort every load.
    # Book.currently_reading (the "keep reading" shelf on the unfiltered
    # root page — the app's most-visited view) groups by book_id and
    # orders by MAX(content_mtime), which benefits from the same index to
    # avoid scanning content_mtime unsorted.
    add_index :reading_states, :content_mtime,
      name: "index_reading_states_on_content_mtime"

    # Library::Clippings.match_book runs `Book.where("LOWER(title) = ?",
    # ...)` for every new clippings entry, and #rematch_unmatched reruns it
    # for every still-unmatched annotation on *every* clippings sync (the
    # daemon re-uploads My Clippings.txt whenever it changes). The existing
    # title index is on the raw column, so it can't serve a LOWER(title)
    # predicate — every call scans the whole books table. An expression
    # index on lower(title) turns that into an index lookup.
    add_index :books, "lower(title)",
      name: "index_books_on_lower_title"

    # Considered and rejected (already covered / not hot enough to be
    # worth the write cost):
    # - device_syncs(device_id, created_at): already exists
    #   (index_device_syncs_on_device_id_and_created_at) and matches both
    #   the device page's per-device history and the retention sweep in
    #   Api::V1::DeviceStatusesController exactly.
    # - conversions active-scope lookups: already covered by
    #   index_conversions_on_active_book_target (partial, unique).
    # - books(description, enriched_at) for the enrichment-candidate scan:
    #   real query (CatalogOperationJob#enrich_all,
    #   LibraryScansController#show), but the controller's count is cached
    #   for 1 minute (Rails.cache "catalog_counts") and enrich_all is a
    #   rare, manual, catalog-wide batch action — not repeated enough to
    #   earn a write-time cost on every book insert/update.
    # - reading_states/annotations per-device or per-book point lookups:
    #   already narrowed to a small row set by existing single-column
    #   indexes (index_reading_states_on_book_id/device_id,
    #   index_annotations_on_device_id) before any further filtering.
  end
end
