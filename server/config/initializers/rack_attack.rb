# Rate limiting for the device API (/api/v1/*), which the real Kindle
# daemon polls with its per-device token roughly every 30s. During an
# active sync it bursts: one manifest fetch, N book + thumbnail downloads,
# a device/status POST, a clippings PUT, and a reading-state PUT per book
# whose progress changed — realistically well under 40 requests inside
# that burst. The limits below are set generously above that (~10x) so a
# real device is never throttled in normal operation; they exist only to
# stop a runaway or abusive client (a bug in a daemon fork, a leaked token
# replayed by a script, etc).
#
# Do NOT tighten these without first re-measuring real daemon traffic —
# see the burst description above.
class Rack::Attack
  Rack::Attack.cache.store = Rails.cache

  # Broad ceiling across the whole device API, keyed by the device's own
  # token so one device's traffic can never count against another's
  # budget. Falls back to IP only for the rare unauthenticated/malformed
  # request (which authenticate_device! rejects anyway).
  DEVICE_API_LIMIT = 300
  DEVICE_API_PERIOD = 1.minute

  throttle("device_api/token", limit: DEVICE_API_LIMIT, period: DEVICE_API_PERIOD) do |req|
    if req.path.start_with?("/api/v1/")
      req.get_header("HTTP_X_API_TOKEN").presence || req.ip
    end
  end

  # Tighter limit specifically on the large-body write endpoints (reading
  # state bundles up to 20MB, clippings up to 10MB — see
  # Api::V1::ReadingStatesController::MAX_BUNDLE_BYTES and
  # Api::V1::ClippingsController::MAX_SIZE, both left untouched here). A
  # real sync writes a handful of these per pass, nowhere near this limit;
  # it guards against a client repeatedly hammering the expensive-to-store
  # endpoints rather than just polling for reads.
  WRITE_HEAVY_LIMIT = 60
  WRITE_HEAVY_PERIOD = 1.minute
  WRITE_HEAVY_PATHS = %r{\A/api/v1/(books/[^/]+/reading_state|clippings)\z}

  throttle("device_api/writes", limit: WRITE_HEAVY_LIMIT, period: WRITE_HEAVY_PERIOD) do |req|
    if req.put? && req.path.match?(WRITE_HEAVY_PATHS)
      req.get_header("HTTP_X_API_TOKEN").presence || req.ip
    end
  end

  # Let a throttled client know when to retry instead of hammering
  # immediately (same spirit as the Retry-After the API already sends on a
  # busy-database 503 — see Api::V1::BaseController).
  self.throttled_response_retry_after_header = true
end

# Never let this affect the test suite (it would make timing/order-
# dependent request specs flaky); the one spec that exercises the
# throttle directly flips this on locally and resets it afterwards.
Rack::Attack.enabled = !Rails.env.test?
