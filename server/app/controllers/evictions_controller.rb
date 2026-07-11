# Web-side "remove from Kindle": marks a delivered book for eviction so
# the daemon deletes it on the next sync (create), or cancels a pending
# eviction that hasn't been performed yet (destroy).
class EvictionsController < ApplicationController
  def create
    delivery = Delivery.find(params[:delivery_id])
    delivery.request_eviction!("requested from web") unless delivery.evict_requested?
    redirect_back fallback_location: device_path(delivery.device),
      notice: "#{delivery.book.title} will be removed from #{delivery.device.name} on next sync."
  end

  def destroy
    delivery = Delivery.find(params[:delivery_id])
    delivery.cancel_eviction! if delivery.evict_requested? && !delivery.removed?
    redirect_back fallback_location: device_path(delivery.device),
      notice: "Removal cancelled.", status: :see_other
  end
end
