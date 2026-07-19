require "rails_helper"

RSpec.describe "OPDS acquisition feeds", type: :request do
  let!(:user) { create(:user, password: "password") }
  let(:auth) { { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(user.email_address, "password") } }
  let(:ns) { { "a" => "http://www.w3.org/2005/Atom", "os" => "http://a9.com/-/spec/opensearch/1.1/" } }

  describe "GET /opds/books" do
    let!(:deliverable) { create(:book, title: "Has A File") }
    let!(:epub) { create(:book_file, :on_disk, book: deliverable, format: "epub") }
    let!(:azw3) { create(:book_file, :on_disk, book: deliverable, format: "azw3") }
    let!(:undeliverable) { create(:book, title: "No File At All") }

    before do
      FileUtils.mkdir_p(Library.covers_root)
      File.binwrite(Library.cover_path(deliverable), "\xFF\xD8fakejpeg")
    end

    it "lists a book with a downloadable file, with acquisition + image links, and excludes a book with none" do
      get "/opds/books", headers: auth

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to eq("application/atom+xml;profile=opds-catalog;kind=acquisition; charset=utf-8")

      doc = Nokogiri::XML(response.body) { |config| config.strict }
      titles = doc.xpath("//a:entry/a:title", ns).map(&:text)
      expect(titles).to include("Has A File")
      expect(titles).not_to include("No File At All")

      entry = doc.at_xpath("//a:entry[a:title='Has A File']", ns)
      acquisition_links = entry.xpath("a:link[@rel='http://opds-spec.org/acquisition']", ns)
      hrefs_and_types = acquisition_links.map { |l| [ l["href"], l["type"] ] }
      expect(hrefs_and_types).to contain_exactly(
        [ "http://www.example.com/opds/entries/#{deliverable.public_id}/file?fmt=azw3", "application/x-mobipocket-ebook" ],
        [ "http://www.example.com/opds/entries/#{deliverable.public_id}/file?fmt=epub", "application/epub+zip" ]
      )

      image_link = entry.at_xpath("a:link[@rel='http://opds-spec.org/image']", ns)
      expect(image_link["href"]).to eq("http://www.example.com/opds/entries/#{deliverable.public_id}/cover")
      thumb_link = entry.at_xpath("a:link[@rel='http://opds-spec.org/image/thumbnail']", ns)
      expect(thumb_link["href"]).to eq("http://www.example.com/opds/entries/#{deliverable.public_id}/thumbnail")
    end

    it "excludes a book whose only file is unavailable (e.g. a missing scanned file)" do
      unavailable_book = create(:book, title: "File Went Missing")
      create(:book_file, book: unavailable_book, format: "epub", available: false, path: "/nonexistent/#{SecureRandom.hex}.epub", source: "scan")

      get "/opds/books", headers: auth

      doc = Nokogiri::XML(response.body) { |config| config.strict }
      titles = doc.xpath("//a:entry/a:title", ns).map(&:text)
      expect(titles).not_to include("File Went Missing")
    end
  end

  describe "pagination" do
    # One over Opds::BaseController::PER_PAGE (48) so /opds/books spans
    # exactly two pages — exercises the real page size rather than a
    # stubbed one.
    let!(:books) do
      Array.new(Opds::BaseController::PER_PAGE + 1) { |n| create(:book, title: "Paged #{n}") }
    end

    before do
      books.each { |book| create(:book_file, :on_disk, book: book, format: "epub") }
    end

    it "emits RFC 5005 first/self/next/last link rels across pages, and previous once past page 1" do
      get "/opds/books", headers: auth

      doc = Nokogiri::XML(response.body) { |config| config.strict }
      expect(doc.at_xpath("//a:link[@rel='first']", ns)).not_to be_nil
      expect(doc.at_xpath("//a:link[@rel='next']", ns)["href"]).to include("page=2")
      expect(doc.at_xpath("//a:link[@rel='last']", ns)["href"]).to include("page=2")
      expect(doc.at_xpath("//a:link[@rel='previous']", ns)).to be_nil
      expect(doc.at_xpath("//os:totalResults", ns).text).to eq((Opds::BaseController::PER_PAGE + 1).to_s)
      expect(doc.at_xpath("//os:itemsPerPage", ns).text).to eq(Opds::BaseController::PER_PAGE.to_s)

      get "/opds/books", params: { page: 2 }, headers: auth
      doc = Nokogiri::XML(response.body) { |config| config.strict }
      expect(doc.at_xpath("//a:link[@rel='previous']", ns)["href"]).to include("page=1")
      expect(doc.at_xpath("//a:link[@rel='next']", ns)).to be_nil
      expect(doc.xpath("//a:entry", ns).size).to eq(1)
    end
  end

  describe "GET /opds/new" do
    it "lists deliverable books newest first" do
      old_book = create(:book, title: "Older", created_at: 2.days.ago)
      create(:book_file, :on_disk, book: old_book, format: "epub")
      new_book = create(:book, title: "Newer", created_at: 1.hour.ago)
      create(:book_file, :on_disk, book: new_book, format: "epub")

      get "/opds/new", headers: auth

      doc = Nokogiri::XML(response.body) { |config| config.strict }
      titles = doc.xpath("//a:entry/a:title", ns).map(&:text)
      expect(titles.index("Newer")).to be < titles.index("Older")
    end
  end
end
