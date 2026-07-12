# A tiny "did anything change?" probe. The daemon hits this every ~30s
# while the Kindle is awake and only runs a full sync when the version
# moves — near-realtime deliveries without waking the radio when idle
# (a suspended Kindle freezes the daemon anyway).
class Api::V1::QueueVersionsController < Api::V1::BaseController
  def show
    render json: { version: current_device.queue_version }
  end
end
