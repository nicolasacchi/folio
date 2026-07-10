require 'rails_helper'

RSpec.describe "API v1 book files", type: :request do
  let!(:device) { create(:device) }
  let(:headers) { { "X-Api-Token" => device.token } }
  let!(:book) { create(:book) }
  let!(:azw3) { create(:book_file, :on_disk, book: book, format: "azw3") }
  let!(:epub) { create(:book_file, :on_disk, book: book, format: "epub") }

  it "serves the preferred Kindle file by default" do
    get "/api/v1/books/#{book.public_id}/file", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.body).to eq(File.read(azw3.absolute_path))
    expect(response.headers["Content-Disposition"]).to include("attachment")
  end

  it "serves an explicitly requested format" do
    get "/api/v1/books/#{book.public_id}/file", params: { fmt: "epub" }, headers: headers

    expect(response.body).to eq(File.read(epub.absolute_path))
  end

  it "404s for a format the book does not have" do
    get "/api/v1/books/#{book.public_id}/file", params: { fmt: "pdf" }, headers: headers

    expect(response).to have_http_status(:not_found)
  end
end
