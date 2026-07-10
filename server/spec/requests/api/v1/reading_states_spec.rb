require 'rails_helper'

RSpec.describe "API v1 reading states", type: :request do
  let!(:device) { create(:device, name: "kindle-a") }
  let!(:other_device) { create(:device, name: "kindle-b") }
  let!(:book) { create(:book) }
  let(:headers) { { "X-Api-Token" => device.token, "CONTENT_TYPE" => "application/gzip" } }

  describe "PUT /api/v1/books/:public_id/reading_state" do
    it "stores the bundle and its content mtime" do
      put "/api/v1/books/#{book.public_id}/reading_state",
        params: "sdr-bundle-bytes",
        headers: headers.merge("X-Sdr-Mtime" => "1752150000")

      expect(response).to have_http_status(:ok)
      state = book.reading_states.sole
      expect(state.device).to eq(device)
      expect(state.content_mtime.to_i).to eq(1_752_150_000)
      expect(File.binread(state.absolute_path)).to eq("sdr-bundle-bytes")
    end

    it "requires the X-Sdr-Mtime header" do
      put "/api/v1/books/#{book.public_id}/reading_state",
        params: "sdr-bundle-bytes", headers: headers

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "404s for unknown books" do
      put "/api/v1/books/nope/reading_state",
        params: "x", headers: headers.merge("X-Sdr-Mtime" => "1")

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/books/:public_id/reading_state" do
    it "404s when no state exists" do
      get "/api/v1/books/#{book.public_id}/reading_state", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "returns the newest bundle across devices" do
      put "/api/v1/books/#{book.public_id}/reading_state",
        params: "old-bundle",
        headers: { "X-Api-Token" => device.token, "CONTENT_TYPE" => "application/gzip", "X-Sdr-Mtime" => "1000" }
      put "/api/v1/books/#{book.public_id}/reading_state",
        params: "new-bundle",
        headers: { "X-Api-Token" => other_device.token, "CONTENT_TYPE" => "application/gzip", "X-Sdr-Mtime" => "2000" }

      get "/api/v1/books/#{book.public_id}/reading_state", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Sdr-Mtime"]).to eq("2000")
      expect(response.headers["X-Sdr-Device-Id"]).to eq(other_device.id.to_s)
      expect(response.body).to eq("new-bundle")
    end
  end
end
