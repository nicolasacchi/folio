# Device-facing API used by the kindled daemon. Authenticates with a
# per-device token, not the web session.
class Api::V1::BaseController < ActionController::API
  before_action :authenticate_device!

  attr_reader :current_device

  # A write stuck behind the busy timeout (bulk jobs hold SQLite's write
  # lock) is a retry-later, not a server bug; the daemon polls again anyway.
  rescue_from ActiveRecord::StatementTimeout do
    response.headers["Retry-After"] = "60"
    render json: { error: "database busy" }, status: :service_unavailable
  end

  private

  def authenticate_device!
    @current_device = Device.authenticate_by_token(device_token)
    return render json: { error: "unauthorized" }, status: :unauthorized unless @current_device

    @current_device.touch_last_seen!
  end

  def device_token
    request.headers["X-Api-Token"].presence ||
      request.authorization.to_s[/\ABearer (.+)\z/, 1]
  end

  # Scopes book lookups to exactly what this device's manifest lists — a
  # device may only fetch the file/thumbnail/reading-state of a book that
  # is actually queued to it. Mirrors ManifestsController#show's `items`
  # scope (active deliveries not pending eviction) so an in-flight
  # download never breaks: if the manifest lists it, this finds it; the
  # moment eviction is requested (and the book drops out of `items` into
  # `removals`), it 404s here too.
  def find_delivered_book!
    delivery = current_device.deliveries.active.where(evict_requested_at: nil)
      .joins(:book).find_by(books: { public_id: params[:public_id] })
    return delivery.book if delivery

    render json: { error: "book not found" }, status: :not_found
    nil
  end
end
