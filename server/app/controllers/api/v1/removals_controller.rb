# The daemon acks an eviction after deleting the file on-device; the
# delivery row stays behind as history ("was on this device, removed").
class Api::V1::RemovalsController < Api::V1::BaseController
  def ack
    delivery = current_device.deliveries.find_by(id: params[:id])
    return render json: { error: "removal not found" }, status: :not_found unless delivery

    delivery.mark_removed! unless delivery.removed?
    render json: { ok: true }
  end
end
