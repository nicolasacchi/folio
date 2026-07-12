require 'rails_helper'

RSpec.describe "API v1 queue version", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:device) { create(:device) }
  let(:headers) { { "X-Api-Token" => device.token } }

  def version
    get "/api/v1/queue_version", headers: headers
    response.parsed_body.fetch("version")
  end

  it "requires a token" do
    get "/api/v1/queue_version"
    expect(response).to have_http_status(:unauthorized)
  end

  it "starts at zero and moves when the queue changes" do
    expect(version).to eq(0)

    book = create(:book)
    create(:book_file, book: book, format: "azw3")
    delivery = nil
    travel_to(5.minutes.from_now) { delivery = create(:delivery, book: book, device: device) }
    first = version
    expect(first).to be > 0

    travel_to(10.minutes.from_now) { delivery.update!(evict_requested_at: Time.current) }
    expect(version).to be > first
  end

  it "moves when a queued book's file is re-prepared" do
    book = create(:book)
    file = create(:book_file, book: book, format: "azw3")
    create(:delivery, book: book, device: device)
    before = version

    travel_to(5.minutes.from_now) { file.update!(prepared_at: Time.current) }
    expect(version).to be > before
  end

  it "moves when another device pushes reading state for a queued book" do
    book = create(:book)
    create(:delivery, book: book, device: device)
    other = create(:device)
    before = version

    travel_to(5.minutes.from_now) { create(:reading_state, book: book, device: other) }
    expect(version).to be > before
  end
end
