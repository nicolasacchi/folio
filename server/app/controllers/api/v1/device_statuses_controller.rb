# Telemetry the daemon POSTs after every sync pass: storage, battery,
# firmware, the sync report, and the list of books it actually has on
# disk. Keeps the device page truthful and drives auto-eviction.
class Api::V1::DeviceStatusesController < Api::V1::BaseController
  def create
    update_device!
    record_sync!
    reconcile_on_device_books!
    auto_evict! if current_device.auto_evict?

    render json: {
      ok: true,
      low_space: current_device.low_space?,
      evictions_pending: current_device.deliveries.evict_requested.count
    }
  end

  private

  def update_device!
    attrs = {
      status_reported_at: Time.current,
      last_sync_at: Time.current
    }
    attrs[:free_bytes] = params[:free_bytes].to_i if params[:free_bytes].present?
    attrs[:total_bytes] = params[:total_bytes].to_i if params[:total_bytes].present?
    attrs[:battery_percent] = params[:battery_percent].to_i if params[:battery_percent].present?
    attrs[:firmware_version] = printable(params[:firmware_version], 100) if params[:firmware_version].present?
    attrs[:serial] = printable(params[:serial], 100) if params[:serial].present?
    attrs[:kindled_version] = printable(params[:kindled_version], 40) if params[:kindled_version].present?
    current_device.update!(attrs)
  end

  # /proc/usid and friends can carry trailing NULs; keep stored values clean.
  def printable(value, max)
    value.to_s.scrub.gsub(/[^[:print:]]/, "").strip.first(max)
  end

  def record_sync!
    report = params[:sync]
    return unless report.is_a?(ActionController::Parameters) || report.is_a?(Hash)

    report = report.permit(:downloaded, :sdr_pushed, :sdr_applied, :removed, :errors, :duration_ms) if report.respond_to?(:permit)
    current_device.device_syncs.create!(
      downloaded_count: report[:downloaded].to_i,
      sdr_pushed_count: report[:sdr_pushed].to_i,
      sdr_applied_count: report[:sdr_applied].to_i,
      removed_count: report[:removed].to_i,
      error_count: report[:errors].to_i,
      duration_ms: report[:duration_ms].presence&.to_i,
      free_bytes: current_device.free_bytes,
      battery_percent: current_device.battery_percent
    )
    prune_sync_history!
  end

  # The daemon reports what is really on disk. Deliveries the device no
  # longer has (user deleted on-device, factory reset…) get closed out;
  # pending ones it does have get their delivered stamp back-filled.
  def reconcile_on_device_books!
    return unless params[:books].is_a?(Array)

    reported = params[:books].filter_map { |b| b[:id].presence }.to_set
    return if reported.empty? && current_device.deliveries.on_device.none?

    current_device.deliveries.active.includes(:book).find_each do |delivery|
      on_device = reported.include?(delivery.book.public_id)
      if delivery.delivered? && !on_device && !delivery.evict_requested? &&
          delivery.delivered_at < 1.hour.ago
        # Not a race with an in-flight pass: the book has really vanished
        # from the device (deleted on-device, reset…).
        delivery.update!(removed_at: Time.current, evict_reason: "missing on device")
      elsif !delivery.delivered? && on_device
        delivery.update!(delivered_at: Time.current)
      end
    end
  end

  def auto_evict!
    current_device.eviction_plan.each do |suggestion|
      suggestion.delivery.request_eviction!("auto: #{suggestion.reason}")
    end
  end

  # Keep a generous but bounded history per device.
  def prune_sync_history!
    ids = current_device.device_syncs.order(created_at: :desc).offset(500).pluck(:id)
    DeviceSync.where(id: ids).delete_all if ids.any?
  end
end
