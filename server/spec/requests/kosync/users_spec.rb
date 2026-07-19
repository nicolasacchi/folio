require "rails_helper"

# Registration + auth-check calls of the kosync protocol (see
# Kosync::UsersController). `password` on the wire is already the MD5-hex
# of the plaintext — KOReader hashes client-side before sending it — so
# these specs send md5 hex, exactly like a real client, never plaintext.
RSpec.describe "kosync users", type: :request do
  let(:json_headers) { { "CONTENT_TYPE" => "application/json" } }
  let(:key) { Digest::MD5.hexdigest("secret") }

  def auth_headers(username, key)
    { "X-Auth-User" => username, "X-Auth-Key" => key }
  end

  describe "POST /kosync/users/create" do
    it "registers a new account" do
      post "/kosync/users/create",
        params: { username: "alice", password: key }.to_json, headers: json_headers

      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to eq("username" => "alice")
    end

    it "stores a bcrypt digest of the md5 key, never the key itself" do
      post "/kosync/users/create",
        params: { username: "alice", password: key }.to_json, headers: json_headers

      credential = KosyncCredential.find_by!(username: "alice")
      expect(credential.key_digest).not_to eq(key)
      expect(credential.authenticate_key(key)).to eq(credential)
    end

    it "rejects a duplicate username with the reference server's conflict status" do
      create(:kosync_credential, username: "alice")

      post "/kosync/users/create",
        params: { username: "alice", password: key }.to_json, headers: json_headers

      expect(response).to have_http_status(:payment_required)
      expect(response.parsed_body).to eq("code" => 2002, "message" => "Username is already registered.")
    end

    it "rejects a blank username or key" do
      post "/kosync/users/create",
        params: { username: "", password: key }.to_json, headers: json_headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["code"]).to eq(2003)
    end

    it "can be disabled via KOSYNC_OPEN_REGISTRATION" do
      original = ENV["KOSYNC_OPEN_REGISTRATION"]
      ENV["KOSYNC_OPEN_REGISTRATION"] = "false"

      post "/kosync/users/create",
        params: { username: "alice", password: key }.to_json, headers: json_headers

      expect(response).to have_http_status(:payment_required)
      expect(response.parsed_body).to eq("code" => 2005, "message" => "User registration is disabled.")
    ensure
      ENV["KOSYNC_OPEN_REGISTRATION"] = original
    end
  end

  describe "GET /kosync/users/auth" do
    let!(:credential) { create(:kosync_credential, username: "alice", key: key) }

    it "authorizes correct credentials" do
      get "/kosync/users/auth", headers: auth_headers("alice", key)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("authorized" => "OK")
    end

    it "401s on the wrong key" do
      get "/kosync/users/auth", headers: auth_headers("alice", "wrongkey")

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq("code" => 2001, "message" => "Unauthorized")
    end

    it "401s on an unknown username" do
      get "/kosync/users/auth", headers: auth_headers("nobody", key)

      expect(response).to have_http_status(:unauthorized)
    end

    it "401s with no auth headers at all" do
      get "/kosync/users/auth"

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
