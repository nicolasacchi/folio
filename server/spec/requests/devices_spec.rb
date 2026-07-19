require "rails_helper"

RSpec.describe "Device settings", type: :request do
  let!(:user) { create(:user) }

  def sign_in(user, password: "password")
    post session_path, params: { email_address: user.email_address, password: password }
  end

  before { sign_in(user) }

  describe "reader write-back toggle" do
    it "shows the toggle on a physical device's page" do
      device = create(:device, kind: "kindle")

      get device_path(device)

      expect(response.body).to include("Web reader position sync")
    end

    it "flips reader_writeback via PATCH" do
      device = create(:device, kind: "kindle", reader_writeback: false)

      patch device_path(device), params: { device: { reader_writeback: true } }

      expect(response).to redirect_to(device_path(device))
      expect(device.reload.reader_writeback).to be true
    end

    it "clears reader_writeback when the checkbox is unchecked (unchecked box sends '0')" do
      device = create(:device, kind: "kindle", reader_writeback: true)

      patch device_path(device), params: { device: { reader_writeback: "0" } }

      expect(device.reload.reader_writeback).to be false
    end
  end

  # The synthetic "web" device (Device.web_reader!) owns every web
  # annotation/reading-state row (dependent: :destroy) — it must never be
  # reachable through the device-management UI a user could stumble into
  # (e.g. by guessing its small sequential id), or its own "Remove device"
  # button would wipe every web highlight/note and Kindle write-back
  # history for the household.
  describe "scoping to physical devices" do
    it "404s on show/update/destroy for the synthetic web device" do
      device = Device.web_reader!

      get device_path(device)
      expect(response).to have_http_status(:not_found)

      patch device_path(device), params: { device: { reader_writeback: true } }
      expect(response).to have_http_status(:not_found)

      expect {
        delete device_path(device)
      }.not_to change(Device, :count)
      expect(response).to have_http_status(:not_found)
      expect(Device.exists?(device.id)).to be true
    end

    it "still allows show/update/destroy for a physical device" do
      device = create(:device, kind: "kindle")

      get device_path(device)
      expect(response).to have_http_status(:ok)

      expect {
        delete device_path(device)
      }.to change(Device, :count).by(-1)
    end
  end

  # Library::EvictionPlanner's criteria (finished/never opened/dormant) are
  # otherwise bare tokens on the page — see EvictionPlanner's header comment
  # for the thresholds these hints/legend must stay in sync with.
  describe "eviction reason explanations" do
    it "explains the suggested-removal criteria with a legend and a tooltip on each reason" do
      device = create(:device, free_bytes: 300.megabytes, total_bytes: 8_000_000_000, low_space_threshold_mb: 500)
      book = create(:book)
      create(:book_file, book: book, format: "azw3", size: 250.megabytes)
      create(:reading_state, book: book, device: device, progress_percent: 98, content_mtime: 2.days.ago)
      create(:delivery, :delivered, book: book, device: device, delivered_at: 2.weeks.ago)

      get device_path(device)

      expect(response.body).to include("How suggestions are chosen")
      expect(response.body).to include(%(title="Reading progress is 95% or higher."))
    end

    it "hints at an algorithmic reason queued for removal, but not a manually requested one" do
      device = create(:device)
      dormant_delivery = create(:delivery, :delivered, book: create(:book), device: device)
      dormant_delivery.request_eviction!("dormant 50 days")
      manual_delivery = create(:delivery, :delivered, book: create(:book), device: device)
      manual_delivery.request_eviction!("requested from web")

      get device_path(device)

      expect(response.body).to include(%(<span title="Last opened more than 45 days ago.">dormant 50 days</span>))
      expect(response.body).to include(%(<span>requested from web</span>))
    end
  end
end
