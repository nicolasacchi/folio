require "rails_helper"

# Progress upload/download (see Kosync::SyncsController). Every PUT
# unconditionally overwrites the single row for (credential, document) —
# last-write-wins, matching the reference server exactly.
RSpec.describe "kosync syncs", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:key) { Digest::MD5.hexdigest("secret") }
  let!(:credential) { create(:kosync_credential, username: "alice", key: key) }
  let(:headers) { { "CONTENT_TYPE" => "application/json", "X-Auth-User" => "alice", "X-Auth-Key" => key } }
  let(:document) { "0b229176d4e8db7f6d2b5a4952368d7a" }

  describe "PUT /kosync/syncs/progress" do
    it "requires auth" do
      put "/kosync/syncs/progress",
        params: { document: document, progress: "56", percentage: 0.3, device: "curl" }.to_json,
        headers: { "CONTENT_TYPE" => "application/json" }

      expect(response).to have_http_status(:unauthorized)
    end

    it "stores progress and returns document + timestamp" do
      put "/kosync/syncs/progress",
        params: { document: document, progress: "56", percentage: 0.32, device: "curl", device_id: "dev1" }.to_json,
        headers: headers

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["document"]).to eq(document)
      expect(body["timestamp"]).to be_a(Integer)

      record = credential.kosync_progresses.sole
      expect(record.progress).to eq("56")
      expect(record.percentage).to eq(0.32)
      expect(record.device).to eq("curl")
      expect(record.device_id).to eq("dev1")
    end

    it "rejects a missing document with the reference server's specific code" do
      put "/kosync/syncs/progress",
        params: { progress: "56", percentage: 0.3, device: "curl" }.to_json,
        headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq("code" => 2004, "message" => "Field 'document' not provided.")
    end

    it "rejects a missing required field" do
      put "/kosync/syncs/progress",
        params: { document: document, progress: "56", device: "curl" }.to_json,
        headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["code"]).to eq(2003)
    end

    it "overwrites on a second PUT (last-write-wins), even backward" do
      put "/kosync/syncs/progress",
        params: { document: document, progress: "56", percentage: 0.32, device: "curl" }.to_json,
        headers: headers
      first_timestamp = response.parsed_body["timestamp"]

      travel_to(1.second.from_now) do
        put "/kosync/syncs/progress",
          params: { document: document, progress: "12", percentage: 0.22, device: "kobo" }.to_json,
          headers: headers
      end

      expect(response).to have_http_status(:ok)
      expect(credential.kosync_progresses.count).to eq(1)
      record = credential.kosync_progresses.sole
      expect(record.progress).to eq("12")
      expect(record.percentage).to eq(0.22)
      expect(record.device).to eq("kobo")
      expect(record.synced_at).to be >= first_timestamp
    end

    it "scopes progress rows per credential" do
      other = create(:kosync_credential, username: "bob", key: key)
      put "/kosync/syncs/progress",
        params: { document: document, progress: "56", percentage: 0.32, device: "curl" }.to_json,
        headers: headers

      expect(other.kosync_progresses.where(document: document)).to be_empty
    end
  end

  describe "GET /kosync/syncs/progress/:document" do
    it "requires auth" do
      get "/kosync/syncs/progress/#{document}"

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns {} for a document never synced" do
      get "/kosync/syncs/progress/#{document}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({})
    end

    it "round-trips exactly what was PUT" do
      put "/kosync/syncs/progress",
        params: { document: document, progress: "56", percentage: 0.32, device: "curl", device_id: "dev1" }.to_json,
        headers: headers

      get "/kosync/syncs/progress/#{document}", headers: headers

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body).to include(
        "document" => document,
        "progress" => "56",
        "percentage" => 0.32,
        "device" => "curl",
        "device_id" => "dev1"
      )
      expect(body["timestamp"]).to be_a(Integer)
    end
  end
end
