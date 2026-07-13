require 'rails_helper'

RSpec.describe "API v1 device status", type: :request do
  let!(:device) { create(:device, low_space_threshold_mb: 500) }
  let(:headers) { { "X-Api-Token" => device.token, "CONTENT_TYPE" => "application/json" } }

  it "rejects requests without a token" do
    post "/api/v1/device/status"
    expect(response).to have_http_status(:unauthorized)
  end

  it "stores telemetry and records a sync" do
    post "/api/v1/device/status", headers: headers, params: {
      free_bytes: 4_000_000_000, total_bytes: 6_000_000_000,
      battery_percent: 73, firmware_version: "5.16.2.1.1",
      serial: "G0910A0B", kindled_version: "0.2.0",
      sync: { downloaded: 2, sdr_pushed: 1, sdr_applied: 0, removed: 0, errors: 0, duration_ms: 3200 }
    }.to_json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("ok" => true, "low_space" => false)

    device.reload
    expect(device.free_bytes).to eq(4_000_000_000)
    expect(device.battery_percent).to eq(73)
    expect(device.firmware_version).to eq("5.16.2.1.1")
    expect(device.last_sync_at).to be_present

    sync = device.device_syncs.last
    expect(sync.downloaded_count).to eq(2)
    expect(sync.sdr_pushed_count).to eq(1)
    expect(sync.duration_ms).to eq(3200)
    expect(sync.free_bytes).to eq(4_000_000_000)
  end

  it "records the reader/experiment state the daemon reconciled" do
    post "/api/v1/device/status", headers: headers, params: {
      free_bytes: 4_000_000_000, total_bytes: 6_000_000_000,
      reader_mode: "kpp", experiments_frozen: true
    }.to_json

    device.reload
    expect(device.reader_mode).to eq("kpp")
    expect(device.experiments_frozen).to be(true)
    expect(device.reader_settings_applied_at).to be_present
    expect(device.reader_settings_applied?).to be(true)
  end

  it "flags low space" do
    post "/api/v1/device/status", headers: headers, params: {
      free_bytes: 100.megabytes, total_bytes: 6_000_000_000
    }.to_json

    expect(response.parsed_body["low_space"]).to be(true)
  end

  describe "on-device reconciliation" do
    let!(:book_on_device) { create(:book) }
    let!(:book_gone) { create(:book) }
    let!(:kept) { create(:delivery, :delivered, book: book_on_device, device: device, delivered_at: 2.days.ago) }
    let!(:vanished) { create(:delivery, :delivered, book: book_gone, device: device, delivered_at: 2.days.ago) }

    it "closes deliveries for books missing on the device and backfills present ones" do
      pending_book = create(:book)
      pending = create(:delivery, book: pending_book, device: device)

      post "/api/v1/device/status", headers: headers, params: {
        books: [ { id: book_on_device.public_id }, { id: pending_book.public_id } ]
      }.to_json

      expect(kept.reload.removed_at).to be_nil
      expect(vanished.reload.removed_at).to be_present
      expect(vanished.evict_reason).to eq("missing on device")
      expect(pending.reload).to be_delivered
    end

    it "does not close very recent deliveries (in-flight sync)" do
      vanished.update!(delivered_at: 5.minutes.ago)

      post "/api/v1/device/status", headers: headers, params: {
        books: [ { id: book_on_device.public_id } ]
      }.to_json

      expect(vanished.reload.removed_at).to be_nil
    end
  end

  describe "auto-eviction" do
    it "queues plan suggestions when enabled and space is low" do
      device.update!(auto_evict: true)
      finished = create(:book)
      create(:book_file, book: finished, format: "azw3", size: 300.megabytes)
      create(:reading_state, book: finished, device: device, progress_percent: 100, content_mtime: 3.days.ago)
      delivery = create(:delivery, :delivered, book: finished, device: device, delivered_at: 2.weeks.ago)

      post "/api/v1/device/status", headers: headers, params: {
        free_bytes: 100.megabytes, total_bytes: 6_000_000_000,
        books: [ { id: finished.public_id } ]
      }.to_json

      expect(response.parsed_body["evictions_pending"]).to eq(1)
      expect(delivery.reload).to be_evict_requested
      expect(delivery.evict_reason).to eq("auto: finished")
    end

    it "does nothing when auto-evict is off" do
      finished = create(:book)
      create(:book_file, book: finished, format: "azw3", size: 300.megabytes)
      create(:reading_state, book: finished, device: device, progress_percent: 100, content_mtime: 3.days.ago)
      delivery = create(:delivery, :delivered, book: finished, device: device, delivered_at: 2.weeks.ago)

      post "/api/v1/device/status", headers: headers, params: {
        free_bytes: 100.megabytes, total_bytes: 6_000_000_000
      }.to_json

      expect(delivery.reload).not_to be_evict_requested
    end
  end
end
