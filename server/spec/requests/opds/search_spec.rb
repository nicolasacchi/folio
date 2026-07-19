require "rails_helper"

RSpec.describe "OPDS search", type: :request do
  let!(:user) { create(:user, password: "password") }
  let(:auth) { { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(user.email_address, "password") } }
  let(:ns) { { "a" => "http://www.w3.org/2005/Atom" } }

  let!(:matching) { create(:book, title: "Gardening for Beginners") }
  let!(:matching_file) { create(:book_file, :on_disk, book: matching, format: "epub") }
  let!(:other) { create(:book, title: "Rocket Science") }
  let!(:other_file) { create(:book_file, :on_disk, book: other, format: "epub") }

  before do
    BookSearch.index_book!(matching)
    BookSearch.index_book!(other)
  end

  it "returns only the matching book" do
    get "/opds/search", params: { q: "gardening" }, headers: auth

    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Type"]).to include("kind=acquisition")
    doc = Nokogiri::XML(response.body) { |config| config.strict }
    expect(doc.xpath("//a:entry/a:title", ns).map(&:text)).to eq([ "Gardening for Beginners" ])
  end

  it "excludes a matching book with no downloadable file" do
    undeliverable = create(:book, title: "Gardening Without Files")
    BookSearch.index_book!(undeliverable)

    get "/opds/search", params: { q: "gardening" }, headers: auth

    doc = Nokogiri::XML(response.body) { |config| config.strict }
    expect(doc.xpath("//a:entry/a:title", ns).map(&:text)).to eq([ "Gardening for Beginners" ])
  end

  it "renders the OpenSearch description document" do
    get "/opds/opensearch.xml", headers: auth

    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Type"]).to eq("application/opensearchdescription+xml; charset=utf-8")

    doc = Nokogiri::XML(response.body) { |config| config.strict }
    expect(doc.root.name).to eq("OpenSearchDescription")
    url = doc.at_xpath("//*[local-name()='Url']")
    expect(url["type"]).to eq("application/atom+xml;profile=opds-catalog;kind=acquisition")
    expect(url["template"]).to eq("http://www.example.com/opds/search?q={searchTerms}&page={startPage?}")
  end
end
