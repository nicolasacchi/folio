# The live send-queue across all devices: what's waiting, what's being
# removed, and what landed recently. Updates in place via Turbo morph
# refreshes broadcast from Delivery.
class QueueController < ApplicationController
  def index
    @devices = Device.physical.order(:name).includes(
      deliveries: { book: :book_files }
    )
    @recently_delivered = Delivery.delivered.includes(:device, book: :book_files)
      .order(delivered_at: :desc).limit(20)
  end
end
