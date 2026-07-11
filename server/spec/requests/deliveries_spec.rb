require 'rails_helper'

RSpec.describe "Deliveries", type: :request do
  let!(:user) { create(:user) }
  let!(:book) { create(:book) }
  let!(:device) { create(:device) }

  before do
    post "/session", params: { email_address: user.email_address, password: "password" }
  end

  describe "POST /deliveries" do
    it "queues the book for the device" do
      expect {
        post "/deliveries", params: { book_id: book.id, device_id: device.id }
      }.to change(Delivery, :count).by(1)

      expect(Delivery.last).to have_attributes(book: book, device: device, delivered_at: nil)
    end

    it "is idempotent for an already-queued book" do
      create(:delivery, book: book, device: device)

      expect {
        post "/deliveries", params: { book_id: book.id, device_id: device.id }
      }.not_to change(Delivery, :count)
    end

    it "queues a Kindle-format conversion when the book has none" do
      expect {
        post "/deliveries", params: { book_id: book.id, device_id: device.id }
      }.to have_enqueued_job(EnsureKindleFormatJob).with(book.id)
    end

    it "skips conversion when a Kindle-ready file exists" do
      create(:book_file, book: book, format: "azw3")

      expect {
        post "/deliveries", params: { book_id: book.id, device_id: device.id }
      }.not_to have_enqueued_job(EnsureKindleFormatJob)
    end
  end

  describe "DELETE /deliveries/:id" do
    let!(:delivery) { create(:delivery, book: book, device: device) }

    it "removes the book from the device queue" do
      expect {
        delete "/deliveries/#{delivery.id}"
      }.to change(Delivery, :count).by(-1)
    end
  end

  describe "queue state in the UI" do
    let!(:azw3) { create(:book_file, book: book, format: "azw3") }

    it "offers a send button for an unqueued device" do
      get "/books/#{book.id}"

      expect(response.body).to include("Send to #{device.name}")
    end

    it "shows queued state and per-device counts once queued" do
      create(:delivery, book: book, device: device)

      get "/books/#{book.id}"
      expect(response.body).to include("Queued for #{device.name}")

      get "/devices"
      expect(response.body).to include("0 books on device, 1 queued")
    end
  end
end
