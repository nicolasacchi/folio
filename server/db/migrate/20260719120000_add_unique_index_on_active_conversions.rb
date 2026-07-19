class AddUniqueIndexOnActiveConversions < ActiveRecord::Migration[8.1]
  # EnsureKindleFormatJob's "any active conversion?" check and its create!
  # are a check-then-act race: two workers can both pass the check and both
  # insert an active (pending/running) conversion for the same (book_id,
  # target_format) before either one commits. Production may already carry
  # duplicates from that window, so defensively dedup first, then let the
  # database enforce the invariant going forward.
  def up
    # Keep the most recently created active row per (book_id, target_format);
    # fail the rest rather than destroying them, to preserve history and not
    # orphan anything referencing them. Idempotent: once at most one active
    # row remains per group there's nothing left to match, so re-running
    # this migration (or a future one hitting the same table) is a no-op.
    execute <<~SQL
      UPDATE conversions
      SET status = 'failed',
          error = 'superseded duplicate — deduped by migration',
          finished_at = COALESCE(finished_at, CURRENT_TIMESTAMP),
          updated_at = CURRENT_TIMESTAMP
      WHERE status IN ('pending', 'running')
        AND id NOT IN (
          SELECT c1.id FROM conversions c1
          WHERE c1.status IN ('pending', 'running')
            AND NOT EXISTS (
              SELECT 1 FROM conversions c2
              WHERE c2.book_id = c1.book_id
                AND c2.target_format = c1.target_format
                AND c2.status IN ('pending', 'running')
                AND (
                  c2.created_at > c1.created_at
                  OR (c2.created_at = c1.created_at AND c2.id > c1.id)
                )
            )
        )
    SQL

    add_index :conversions, [ :book_id, :target_format ], unique: true,
      where: "status IN ('pending', 'running')",
      name: "index_conversions_on_active_book_target"
  end

  def down
    remove_index :conversions, name: "index_conversions_on_active_book_target"
  end
end
