require 'rails_helper'

RSpec.describe "API v1 thumbnails", type: :request do
  let!(:device) { create(:device) }
  let(:headers) { { "X-Api-Token" => device.token } }
  let!(:book) { create(:book) }
  let!(:delivery) { create(:delivery, book: book, device: device) }
  let(:thumbnail_path) { Rails.root.join("tmp", "thumbnails_spec_#{book.id}.jpg") }

  # Stubbed so this spec exercises routing/authorization, not libvips'
  # ability to decode a fixture image (see Library::Thumbnails.ensure).
  before do
    File.binwrite(thumbnail_path, "fake-jpeg-bytes")
    allow(Library::Thumbnails).to receive(:ensure).and_return(thumbnail_path)
  end

  after { FileUtils.rm_f(thumbnail_path) }

  it "serves the generated thumbnail for a queued book" do
    get "/api/v1/books/#{book.public_id}/thumbnail", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.body).to eq("fake-jpeg-bytes")
    expect(response.headers["Content-Type"]).to include("image/jpeg")
  end

  it "404s when the book has no cover" do
    allow(Library::Thumbnails).to receive(:ensure).and_return(nil)

    get "/api/v1/books/#{book.public_id}/thumbnail", headers: headers

    expect(response).to have_http_status(:not_found)
  end

  # Regression coverage for the device-API IDOR: a device token must not be
  # able to fetch the thumbnail of a book it was never queued (see
  # BaseController#find_delivered_book!).
  describe "scoping to this device's manifest" do
    it "404s for a book never queued to any device" do
      unqueued = create(:book)

      get "/api/v1/books/#{unqueued.public_id}/thumbnail", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "404s for a book queued only to another device" do
      other_device = create(:device)
      other_book = create(:book)
      create(:delivery, book: other_book, device: other_device)

      get "/api/v1/books/#{other_book.public_id}/thumbnail", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "404s once eviction of this book has been requested" do
      delivery.update!(delivered_at: 1.day.ago)
      delivery.request_eviction!("finished")

      get "/api/v1/books/#{book.public_id}/thumbnail", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end
end
