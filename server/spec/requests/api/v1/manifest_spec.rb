require 'rails_helper'

RSpec.describe "API v1 manifest", type: :request do
  let!(:device) { create(:device) }
  let(:headers) { { "X-Api-Token" => device.token } }

  it "rejects requests without a device token" do
    get "/api/v1/manifest"
    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects requests with a wrong token" do
    get "/api/v1/manifest", headers: { "X-Api-Token" => "nope" }
    expect(response).to have_http_status(:unauthorized)
  end

  describe "items" do
    let!(:ready_book) { create(:book, title: "Ready") }
    let!(:azw3) { create(:book_file, book: ready_book, format: "azw3") }
    let!(:epub_only_book) { create(:book, title: "Epub Only") }
    let!(:epub) { create(:book_file, book: epub_only_book, format: "epub") }
    let!(:unqueued_book) { create(:book, title: "Not Sent") }
    let!(:unqueued_azw3) { create(:book_file, book: unqueued_book, format: "azw3") }
    let!(:other_device) { create(:device) }
    let!(:ready_delivery) { create(:delivery, book: ready_book, device: device) }
    let!(:epub_delivery) { create(:delivery, book: epub_only_book, device: device) }
    let!(:foreign_delivery) { create(:delivery, book: unqueued_book, device: other_device) }

    it "lists only queued books with a Kindle-ready file" do
      get "/api/v1/manifest", headers: headers

      expect(response).to have_http_status(:ok)
      items = response.parsed_body.fetch("items")
      expect(items.size).to eq(1)
      expect(items.first).to include(
        "id" => ready_book.public_id,
        "title" => "Ready",
        "format" => "azw3",
        "sha256" => azw3.sha256
      )
      expect(items.first["url"]).to include(ready_book.public_id)
      expect(items.first["reading_state"]).to be_nil
    end

    context "with a stored reading state" do
      let!(:state) { create(:reading_state, book: ready_book, device: device) }

      it "includes the latest reading-state summary" do
        get "/api/v1/manifest", headers: headers

        summary = response.parsed_body.dig("items", 0, "reading_state")
        expect(summary).to include("sha256" => state.sha256, "mtime" => state.content_mtime.to_i)
      end
    end
  end
end
