require "rails_helper"

RSpec.describe "GET /books/:id/download", type: :request do
  let!(:user) { create(:user) }

  before do
    post session_path, params: { email_address: user.email_address, password: "password" }
  end

  let!(:book) { create(:book) }
  let!(:pdf_file) do
    create(:book_file, book: book, format: "pdf").tap do |file|
      FileUtils.mkdir_p(file.absolute_path.dirname)
      File.write(file.absolute_path, "raw scanned pdf bytes")
      file.update!(size: File.size(file.absolute_path), sha256: Library.sha256(file.absolute_path))
    end
  end

  context "with no OCR companion" do
    it "serves the raw file" do
      get download_book_path(book, fmt: "pdf")

      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq("raw scanned pdf bytes")
    end

    it "still serves the raw file when raw=1 is passed" do
      get download_book_path(book, fmt: "pdf", raw: 1)

      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq("raw scanned pdf bytes")
    end
  end

  context "with a fresh OCR companion" do
    before do
      ocr_path = "ocr/#{pdf_file.id}.ocr.pdf"
      FileUtils.mkdir_p(Library.base_root.join(ocr_path).dirname)
      File.write(Library.base_root.join(ocr_path), "ocr'd pdf bytes with a text layer")
      pdf_file.update!(ocr_path: ocr_path, ocr_source_sha256: pdf_file.sha256)
    end

    it "serves the OCR'd bytes by default" do
      get download_book_path(book, fmt: "pdf")

      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq("ocr'd pdf bytes with a text layer")
      # The visible filename stays the plain pdf name — only the bytes differ.
      expect(response.headers["Content-Disposition"]).to include(pdf_file.filename)
    end

    it "serves the untouched original when raw=1 is passed" do
      get download_book_path(book, fmt: "pdf", raw: 1)

      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq("raw scanned pdf bytes")
    end
  end

  context "with a stale OCR companion (ocr_source_sha256 no longer matches sha256)" do
    before do
      ocr_path = "ocr/#{pdf_file.id}.ocr.pdf"
      FileUtils.mkdir_p(Library.base_root.join(ocr_path).dirname)
      File.write(Library.base_root.join(ocr_path), "ocr'd pdf bytes with a text layer")
      pdf_file.update!(ocr_path: ocr_path, ocr_source_sha256: "no-longer-matches")
    end

    it "serves the raw file's bytes, not the stale companion" do
      get download_book_path(book, fmt: "pdf")

      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq("raw scanned pdf bytes")
    end
  end

  it "redirects with an alert when the requested format does not exist" do
    get download_book_path(book, fmt: "epub")

    expect(response).to redirect_to(book_path(book))
    follow_redirect!
    expect(response.body).to include("File not available.")
  end
end
