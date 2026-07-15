class DevicesController < ApplicationController
  before_action :set_device, only: [ :show, :update, :evict_suggested, :destroy ]

  def index
    @devices = Device.physical.order(:name)
    @device = Device.new
  end

  def show
    @on_device = @device.deliveries.on_device.includes(book: :book_files)
      .sort_by { |d| d.book.title.to_s.downcase }
    @queued = @device.deliveries.pending.includes(book: :book_files).order(created_at: :asc)
    @removing = @device.deliveries.evict_requested.includes(:book).order(evict_requested_at: :desc)
    @removed = @device.deliveries.removed.includes(:book).order(removed_at: :desc).limit(10)
    @syncs = @device.device_syncs.recent.limit(15)
    @reading = @device.reading_states.includes(:book).order(content_mtime: :desc).limit(8)
    @planner = Library::EvictionPlanner.new(@device)
    @plan = @planner.plan
    @on_device_bytes = @on_device.sum { |d| d.book.kindle_file&.size.to_i }
    @annotation_count = @device.annotations.count
  end

  def create
    device = Device.new(device_params)
    if device.save
      redirect_to devices_path, notice: "Device added. Token: #{device.token}"
    else
      redirect_to devices_path, alert: device.errors.full_messages.to_sentence
    end
  end

  def update
    if @device.update(device_settings_params)
      redirect_to device_path(@device), notice: "Device settings saved."
    else
      redirect_to device_path(@device), alert: @device.errors.full_messages.to_sentence
    end
  end

  # One tap applies every suggestion in the current eviction plan.
  def evict_suggested
    plan = @device.eviction_plan
    plan.each { |suggestion| suggestion.delivery.request_eviction!(suggestion.reason) }
    redirect_to device_path(@device),
      notice: plan.any? ? "#{plan.size} #{"removal".pluralize(plan.size)} queued for next sync." : "Nothing to remove."
  end

  def destroy
    @device.destroy!
    redirect_to devices_path, notice: "Device removed.", status: :see_other
  end

  private

  # .physical excludes the synthetic "Folio Web" device (Device.web_reader!)
  # so it 404s here instead of exposing a working destroy/settings UI for it
  # — deleting it would cascade-destroy every web annotation and Kindle
  # write-back sync row for the household (see Device#annotations/
  # #reading_states dependent: :destroy).
  def set_device
    @device = Device.physical.find(params[:id])
  end

  def device_params
    params.expect(device: [ :name ])
  end

  def device_settings_params
    params.expect(device: [ :name, :low_space_threshold_mb, :auto_evict,
                            :modern_reader_pinned, :freeze_experiments, :reader_writeback ])
  end
end
