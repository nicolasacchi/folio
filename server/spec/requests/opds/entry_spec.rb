require "rails_helper"

RSpec.describe "OPDS single-entry document", type: :request do
  let!(:user) { create(:user, password: "password") }
  let(:auth) { { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(user.email_address, "password") } }
  let(:ns) { { "a" => "http://www.w3.org/2005/Atom" } }

  let!(:book) { create(:book, title: "Standalone Entry") }
  let!(:book_file) { create(:book_file, :on_disk, book: book, format: "epub") }

  it "renders a document whose root element is <entry>, with the OPDS entry content type" do
    get "/opds/entries/#{book.public_id}", headers: auth

    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Type"]).to eq("application/atom+xml;type=entry;profile=opds-catalog; charset=utf-8")

    doc = Nokogiri::XML(response.body) { |config| config.strict }
    expect(doc.root.name).to eq("entry")
    expect(doc.root.namespace.href).to eq("http://www.w3.org/2005/Atom")
    expect(doc.at_xpath("/a:entry/a:title", ns).text).to eq("Standalone Entry")
    expect(doc.at_xpath("/a:entry/a:id", ns).text).to eq("urn:folio:book:#{book.public_id}")
  end

  it "404s for an unknown public_id" do
    get "/opds/entries/does-not-exist", headers: auth

    expect(response).to have_http_status(:not_found)
  end

  it "404s for a book with no downloadable file" do
    bare_book = create(:book)

    get "/opds/entries/#{bare_book.public_id}", headers: auth

    expect(response).to have_http_status(:not_found)
  end
end
