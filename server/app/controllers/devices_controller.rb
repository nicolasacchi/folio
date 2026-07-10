class DevicesController < ApplicationController
  def index
    @devices = Device.order(:name)
    @device = Device.new
  end

  def create
    device = Device.new(device_params)
    if device.save
      redirect_to devices_path, notice: "Device added. Token: #{device.token}"
    else
      redirect_to devices_path, alert: device.errors.full_messages.to_sentence
    end
  end

  def destroy
    Device.find(params[:id]).destroy!
    redirect_to devices_path, notice: "Device removed.", status: :see_other
  end

  private

  def device_params
    params.expect(device: [ :name ])
  end
end
