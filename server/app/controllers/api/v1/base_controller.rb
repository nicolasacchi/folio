# Device-facing API used by the kindled daemon. Authenticates with a
# per-device token, not the web session.
class Api::V1::BaseController < ActionController::API
  before_action :authenticate_device!

  attr_reader :current_device

  private

  def authenticate_device!
    @current_device = Device.find_by(token: device_token) if device_token.present?
    return render json: { error: "unauthorized" }, status: :unauthorized unless @current_device

    @current_device.touch_last_seen!
  end

  def device_token
    request.headers["X-Api-Token"].presence ||
      request.authorization.to_s[/\ABearer (.+)\z/, 1]
  end

  def find_book!
    Book.find_by!(public_id: params[:public_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: "book not found" }, status: :not_found
    nil
  end
end
