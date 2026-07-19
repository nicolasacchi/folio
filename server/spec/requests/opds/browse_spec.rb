require "rails_helper"

RSpec.describe "OPDS browse by author/series/category", type: :request do
  let!(:user) { create(:user, password: "password") }
  let(:auth) { { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(user.email_address, "password") } }
  let(:ns) { { "a" => "http://www.w3.org/2005/Atom" } }

  let!(:book) { create(:book, title: "Shelved Book", author: "Ada Lovelace", series: "Analytical Engines", series_index: 2, category: "fiction/sf") }
  let!(:book_file) { create(:book_file, :on_disk, book: book, format: "epub") }

  describe "authors" do
    it "lists the author in the navigation index, linking to the acquisition feed" do
      get "/opds/authors", headers: auth

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to include("kind=navigation")
      doc = Nokogiri::XML(response.body) { |config| config.strict }
      link = doc.at_xpath("//a:entry[a:title='Ada Lovelace']/a:link", ns)
      expect(link["href"]).to eq("http://www.example.com/opds/authors/Ada%20Lovelace")
    end

    it "lists the author's books in an acquisition feed" do
      get "/opds/authors/#{ERB::Util.url_encode('Ada Lovelace')}", headers: auth

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to include("kind=acquisition")
      doc = Nokogiri::XML(response.body) { |config| config.strict }
      expect(doc.xpath("//a:entry/a:title", ns).map(&:text)).to eq([ "Shelved Book" ])
    end
  end

  describe "series" do
    it "lists the series in the navigation index" do
      get "/opds/series", headers: auth

      doc = Nokogiri::XML(response.body) { |config| config.strict }
      link = doc.at_xpath("//a:entry[a:title='Analytical Engines']/a:link", ns)
      expect(link["href"]).to eq("http://www.example.com/opds/series/Analytical%20Engines")
    end

    it "lists the series' books in reading order" do
      companion = create(:book, title: "Book One", series: "Analytical Engines", series_index: 1)
      create(:book_file, :on_disk, book: companion, format: "epub")

      get "/opds/series/#{ERB::Util.url_encode('Analytical Engines')}", headers: auth

      doc = Nokogiri::XML(response.body) { |config| config.strict }
      expect(doc.xpath("//a:entry/a:title", ns).map(&:text)).to eq([ "Book One", "Shelved Book" ])
    end
  end

  describe "categories" do
    it "lists categories in the navigation index" do
      get "/opds/categories", headers: auth

      doc = Nokogiri::XML(response.body) { |config| config.strict }
      link = doc.at_xpath("//a:entry[a:link[@href='http://www.example.com/opds/categories/fiction/sf']]", ns)
      expect(link).not_to be_nil
    end

    it "lists books under the exact leaf category" do
      get "/opds/categories/fiction/sf", headers: auth

      doc = Nokogiri::XML(response.body) { |config| config.strict }
      expect(doc.xpath("//a:entry/a:title", ns).map(&:text)).to eq([ "Shelved Book" ])
    end

    it "lists books under a bare category root too" do
      get "/opds/categories/fiction", headers: auth

      doc = Nokogiri::XML(response.body) { |config| config.strict }
      expect(doc.xpath("//a:entry/a:title", ns).map(&:text)).to eq([ "Shelved Book" ])
    end
  end
end
