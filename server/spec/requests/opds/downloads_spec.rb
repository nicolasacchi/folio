require "rails_helper"

RSpec.describe "OPDS downloads", type: :request do
  let!(:user) { create(:user, password: "password") }
  let(:auth) { { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(user.email_address, "password") } }

  let!(:book) { create(:book) }
  let!(:epub) { create(:book_file, :on_disk, book: book, format: "epub") }
  let!(:azw3) { create(:book_file, :on_disk, book: book, format: "azw3") }

  describe "GET /opds/entries/:public_id/file" do
    it "streams the raw file bytes with the correct MIME type for the requested format" do
      get "/opds/entries/#{book.public_id}/file", params: { fmt: "epub" }, headers: auth

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq(File.read(epub.absolute_path))
      expect(response.headers["Content-Type"]).to include("application/epub+zip")
      expect(response.headers["Content-Disposition"]).to include("attachment")
    end

    it "streams a different requested format" do
      get "/opds/entries/#{book.public_id}/file", params: { fmt: "azw3" }, headers: auth

      expect(response.body).to eq(File.read(azw3.absolute_path))
      expect(response.headers["Content-Type"]).to include("application/x-mobipocket-ebook")
    end

    it "401s without credentials" do
      get "/opds/entries/#{book.public_id}/file", params: { fmt: "epub" }

      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to eq('Basic realm="Folio OPDS"')
    end

    it "404s for a format the book does not have" do
      get "/opds/entries/#{book.public_id}/file", params: { fmt: "pdf" }, headers: auth

      expect(response).to have_http_status(:not_found)
    end

    it "404s for a book with no downloadable file at all" do
      bare_book = create(:book)

      get "/opds/entries/#{bare_book.public_id}/file", headers: auth

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /opds/entries/:public_id/cover" do
    before do
      FileUtils.mkdir_p(Library.covers_root)
      File.binwrite(Library.cover_path(book), "\xFF\xD8fakejpeg")
    end

    it "serves the cover for an authenticated request" do
      get "/opds/entries/#{book.public_id}/cover", headers: auth

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("\xFF\xD8fakejpeg".b)
      expect(response.headers["Content-Type"]).to include("image/jpeg")
    end

    it "401s without credentials" do
      get "/opds/entries/#{book.public_id}/cover"

      expect(response).to have_http_status(:unauthorized)
    end

    it "404s when the book has no cover" do
      FileUtils.rm_f(Library.cover_path(book))

      get "/opds/entries/#{book.public_id}/cover", headers: auth

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /opds/entries/:public_id/thumbnail" do
    let(:thumbnail_path) { Rails.root.join("tmp", "opds_thumbnail_spec_#{book.id}.jpg") }

    before do
      File.binwrite(thumbnail_path, "fake-thumbnail-bytes")
      allow(Library::Thumbnails).to receive(:ensure).and_return(thumbnail_path)
    end

    after { FileUtils.rm_f(thumbnail_path) }

    it "serves the generated thumbnail for an authenticated request" do
      get "/opds/entries/#{book.public_id}/thumbnail", headers: auth

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("fake-thumbnail-bytes")
    end

    it "401s without credentials" do
      get "/opds/entries/#{book.public_id}/thumbnail"

      expect(response).to have_http_status(:unauthorized)
    end

    it "404s without a cover to derive a thumbnail from" do
      allow(Library::Thumbnails).to receive(:ensure).and_return(nil)

      get "/opds/entries/#{book.public_id}/thumbnail", headers: auth

      expect(response).to have_http_status(:not_found)
    end
  end
end
