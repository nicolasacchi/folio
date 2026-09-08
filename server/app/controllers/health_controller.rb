# Deeper liveness check than /healthz (rails/health#show), which only
# proves Puma booted. This proves the primary SQLite DB actually accepts
# writes and that a Solid Queue worker is still heartbeating. Unauthenticated
# by convention, like the other health routes — skip ApplicationController
# so we don't inherit the web-session Authentication concern.
class HealthController < ActionController::Base
  # Whether a stale Solid Queue heartbeat should flip this endpoint to 503.
  # Off by default: /healthz (not this endpoint) is what the Kindle daemon
  # and uptime monitors depend on, and a lagging/restarting queue worker
  # shouldn't page anyone while the DB and web process are otherwise fine.
  # Flip to true to make a stale queue fatal too.
  QUEUE_STALE_IS_FATAL = false

  # A worker that hasn't heartbeated within this window is considered gone.
  QUEUE_HEARTBEAT_WINDOW = 5.minutes

  # The DB write probe (below) is a CREATE + INSERT on every hit; cache the
  # outcome for a few seconds so a burst of monitor scrapes costs one real
  # probe instead of one write per request. A cached "down" flips back to
  # "ok" at most this long after recovery — acceptable for a liveness feed.
  DB_PROBE_CACHE_KEY = "healthz/deep/db_writable"
  DB_PROBE_TTL = 5.seconds

  def deep
    db_ok = database_writable?
    queue_ok = !queue_stale?
    healthy = db_ok && (queue_ok || !QUEUE_STALE_IS_FATAL)

    render json: { db: db_ok ? "ok" : "down", queue: queue_ok ? "ok" : "stale" },
           status: healthy ? :ok : :service_unavailable
  end

  private

  # A real write (create + insert), rolled back — proves the DB file is
  # actually writable, not just that a SELECT works (which a read-only
  # filesystem or a wedged lock would still happily answer). Probed through
  # the cache (see DB_PROBE_TTL); both true and false are cached, so a
  # down-DB burst doesn't turn into a write-attempt storm either.
  def database_writable?
    Rails.cache.fetch(DB_PROBE_CACHE_KEY, expires_in: DB_PROBE_TTL) { probe_database_write }
  rescue StandardError => e
    # The cache backend is Solid Cache — the same SQLite cluster this probe
    # is checking. If the cache itself is wedged, fall back to probing
    # directly rather than 500ing (or falsely 503ing) the health endpoint.
    Rails.logger.error("[health#deep] probe cache failed, probing directly: #{e.class}")
    probe_database_write
  end

  def probe_database_write
    ActiveRecord::Base.transaction(requires_new: true) do
      ActiveRecord::Base.connection.execute("CREATE TABLE IF NOT EXISTS health_check_probes (id integer PRIMARY KEY)")
      ActiveRecord::Base.connection.execute("INSERT INTO health_check_probes (id) VALUES (1)")
      raise ActiveRecord::Rollback
    end
    true
  rescue StandardError => e
    Rails.logger.error("[health#deep] DB write check failed: #{e.class}")
    false
  end

  def queue_stale?
    SolidQueue::Process.where("last_heartbeat_at > ?", QUEUE_HEARTBEAT_WINDOW.ago).none?
  rescue StandardError => e
    Rails.logger.error("[health#deep] Queue heartbeat check failed: #{e.class}")
    true
  end
end
