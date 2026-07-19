require "rails_helper"

RSpec.describe "OPDS authentication", type: :request do
  let!(:user) { create(:user, email_address: "reader@example.com", password: "password") }
  let(:auth) { basic_auth("reader@example.com", "password") }

  let!(:book) { create(:book) }
  let!(:book_file) { create(:book_file, :on_disk, book: book, format: "epub") }

  def basic_auth(email, password)
    { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(email, password) }
  end

  it "401s a feed request with no credentials" do
    get "/opds"

    expect(response).to have_http_status(:unauthorized)
    expect(response.headers["WWW-Authenticate"]).to eq('Basic realm="Folio OPDS"')
  end

  it "401s a feed request with a wrong password" do
    get "/opds", headers: basic_auth("reader@example.com", "wrong")

    expect(response).to have_http_status(:unauthorized)
    expect(response.headers["WWW-Authenticate"]).to eq('Basic realm="Folio OPDS"')
  end

  it "401s a feed request for an unknown email" do
    get "/opds", headers: basic_auth("nobody@example.com", "password")

    expect(response).to have_http_status(:unauthorized)
  end

  it "401s an acquisition download with no credentials" do
    get "/opds/entries/#{book.public_id}/file", params: { fmt: "epub" }

    expect(response).to have_http_status(:unauthorized)
    expect(response.headers["WWW-Authenticate"]).to eq('Basic realm="Folio OPDS"')
  end

  it "401s a cover download with no credentials" do
    get "/opds/entries/#{book.public_id}/cover"

    expect(response).to have_http_status(:unauthorized)
  end

  it "401s a thumbnail download with no credentials" do
    get "/opds/entries/#{book.public_id}/thumbnail"

    expect(response).to have_http_status(:unauthorized)
  end

  it "401s the OpenSearch description with no credentials" do
    get "/opds/opensearch.xml"

    expect(response).to have_http_status(:unauthorized)
  end

  it "lets a correctly authenticated request through to the feed" do
    get "/opds", headers: auth

    expect(response).to have_http_status(:ok)
  end

  it "lets a correctly authenticated request through to a download" do
    get "/opds/entries/#{book.public_id}/file", params: { fmt: "epub" }, headers: auth

    expect(response).to have_http_status(:ok)
  end
end
