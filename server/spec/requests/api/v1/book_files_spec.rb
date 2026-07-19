require 'rails_helper'

RSpec.describe "API v1 book files", type: :request do
  let!(:device) { create(:device) }
  let(:headers) { { "X-Api-Token" => device.token } }
  let!(:book) { create(:book) }
  let!(:azw3) { create(:book_file, :on_disk, book: book, format: "azw3") }
  let!(:epub) { create(:book_file, :on_disk, book: book, format: "epub") }
  let!(:delivery) { create(:delivery, book: book, device: device) }

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

  # Regression coverage for the device-API IDOR: a device token must not
  # reach a file for a book it was never queued (see BaseController#find_delivered_book!).
  describe "scoping to this device's manifest" do
    it "404s for a book never queued to any device" do
      unqueued = create(:book)
      create(:book_file, :on_disk, book: unqueued, format: "azw3")

      get "/api/v1/books/#{unqueued.public_id}/file", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "404s for a book queued only to another device" do
      other_device = create(:device)
      other_book = create(:book)
      create(:book_file, :on_disk, book: other_book, format: "azw3")
      create(:delivery, book: other_book, device: other_device)

      get "/api/v1/books/#{other_book.public_id}/file", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "404s once eviction of this book has been requested" do
      delivery.update!(delivered_at: 1.day.ago)
      delivery.request_eviction!("finished")

      get "/api/v1/books/#{book.public_id}/file", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "delivery tracking" do
    let!(:other_device) { create(:device) }
    let!(:other_delivery) { create(:delivery, book: book, device: other_device) }

    it "marks this device's queued delivery as delivered on download" do
      get "/api/v1/books/#{book.public_id}/file", headers: headers

      expect(delivery.reload).to be_delivered
      expect(other_delivery.reload).not_to be_delivered
    end
  end
end
