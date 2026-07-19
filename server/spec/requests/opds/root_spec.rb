require "rails_helper"

RSpec.describe "OPDS root navigation feed", type: :request do
  let!(:user) { create(:user, password: "password") }
  let(:auth) { { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(user.email_address, "password") } }

  it "renders a valid navigation feed with the expected chrome and nav links" do
    get "/opds", headers: auth

    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Type"]).to eq("application/atom+xml;profile=opds-catalog;kind=navigation; charset=utf-8")

    doc = Nokogiri::XML(response.body) { |config| config.strict }
    ns = { "a" => "http://www.w3.org/2005/Atom" }

    expect(doc.root.name).to eq("feed")
    expect(doc.at_xpath("/a:feed/a:id", ns).text).to eq("urn:folio:opds:root")
    expect(doc.at_xpath("/a:feed/a:title", ns).text).to eq("Folio Library")
    expect(doc.at_xpath("/a:feed/a:updated", ns)).not_to be_nil

    self_link = doc.at_xpath("/a:feed/a:link[@rel='self']", ns)
    expect(self_link["href"]).to eq("http://www.example.com/opds")
    expect(self_link["type"]).to eq("application/atom+xml;profile=opds-catalog;kind=navigation")

    search_link = doc.at_xpath("/a:feed/a:link[@rel='search']", ns)
    expect(search_link["href"]).to eq("http://www.example.com/opds/opensearch.xml")
    expect(search_link["type"]).to eq("application/opensearchdescription+xml")

    subsection_hrefs = doc.xpath("/a:feed/a:entry/a:link[@rel='subsection']", ns).map { |l| l["href"] }
    expect(subsection_hrefs).to include(
      "http://www.example.com/opds/books",
      "http://www.example.com/opds/authors",
      "http://www.example.com/opds/series",
      "http://www.example.com/opds/categories"
    )

    new_link = doc.at_xpath("/a:feed/a:entry/a:link[@rel='http://opds-spec.org/sort/new']", ns)
    expect(new_link["href"]).to eq("http://www.example.com/opds/new")
  end
end
