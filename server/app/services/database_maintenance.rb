# Periodic SQLite housekeeping, run by DatabaseMaintenanceJob.
#
# WAL mode doesn't reclaim the write-ahead log on its own: left unchecked
# it grows without bound and reads slow down as SQLite has to replay more
# of it. `PRAGMA wal_checkpoint(TRUNCATE)` folds the log back into the
# main file and truncates it to zero — see BookSearch/Library::Embeddings
# for the same PRAGMA used to switch these databases into WAL mode in the
# first place.
#
# `PRAGMA quick_check` is a fast structural sanity check — a canary, not a
# full `integrity_check` (which walks every index and can take minutes on
# a multi-GB database). Good enough to catch page-level corruption from a
# crash or a disk fault on a recurring schedule without taking the app out
# of service.
module DatabaseMaintenance
  Result = Struct.new(:label, :checkpoint, :quick_check, keyword_init: true) do
    def ok?
      quick_check.nil? || quick_check == "ok"
    end
  end

  module_function

  # The primary is the priority — it's the database the whole app (web +
  # device API) depends on, so it's the only target that also pays for
  # quick_check. The satellite SQLite databases (Solid Queue, Solid Cache,
  # the FTS/embeddings indexes) just get checkpointed: one extra PRAGMA on
  # connections the app already holds open, cheap enough not to skip, but
  # not worth a second integrity pass on a schedule.
  def run!
    results = [ maintain(:primary, ActiveRecord::Base.connection, quick_check: true) ]
    results << maintain(:queue, SolidQueue::Record.connection) if defined?(SolidQueue::Record)
    results << maintain(:cache, SolidCache::Record.connection) if defined?(SolidCache::Record)
    results << maintain_raw(:fulltext_index, BookSearch)
    results << maintain_raw(:embeddings, Library::Embeddings) if Library::Embeddings.available?

    results.compact.each { |result| log(result) }
    results.compact
  end

  # `connection` is either an ActiveRecord connection adapter or a raw
  # SQLite3::Database (BookSearch/Library::Embeddings keep their own
  # handles outside the AR connection pool) — both respond to #execute the
  # same way, just with different row shapes (Hash vs Array), which
  # `extract_value` normalizes.
  def maintain(label, connection, quick_check: false)
    checkpoint = connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").first
    check = extract_value(connection.execute("PRAGMA quick_check").first) if quick_check
    Result.new(label: label, checkpoint: checkpoint, quick_check: check)
  rescue StandardError => error
    Rails.logger.error("[DatabaseMaintenance] #{label} failed: #{error.class}: #{error.message}")
    nil
  end

  def maintain_raw(label, owner)
    owner.with_db { |db| maintain(label, db) }
  end

  def extract_value(row)
    row.is_a?(Hash) ? row.values.first : row&.first
  end

  def log(result)
    message = "[DatabaseMaintenance] #{result.label} checkpoint=#{result.checkpoint.inspect}"
    message += " quick_check=#{result.quick_check}" if result.quick_check

    if result.ok?
      Rails.logger.info(message)
    else
      Rails.logger.error("#{message} — primary database may be corrupt")
    end
  end
end
