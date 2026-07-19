require 'rails_helper'

RSpec.describe "API v1 clippings", type: :request do
  let!(:device) { create(:device) }
  let(:headers) { { "X-Api-Token" => device.raw_token, "CONTENT_TYPE" => "text/plain" } }

  let(:body) do
    "The Salt Road (Ada Author)\r\n" \
    "- Your Highlight on page 3 | location 40-42 | Added on Monday, July 6, 2026 9:13:22 PM\r\n" \
    "\r\n" \
    "A line worth keeping.\r\n" \
    "==========\r\n"
  end

  it "requires a token" do
    put "/api/v1/clippings", params: body
    expect(response).to have_http_status(:unauthorized)
  end

  it "imports annotations and persists the raw file" do
    book = create(:book, title: "The Salt Road", author: "Ada Author")

    put "/api/v1/clippings", headers: headers, params: body

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("ok" => true, "imported" => 1, "total" => 1)

    annotation = device.annotations.sole
    expect(annotation.book).to eq(book)
    expect(annotation.content).to eq("A line worth keeping.")

    raw = Library.base_root.join("clippings", "device-#{device.id}.txt")
    expect(File.read(raw)).to eq(body)
  end

  it "is idempotent across re-uploads" do
    2.times { put "/api/v1/clippings", headers: headers, params: body }
    expect(device.annotations.count).to eq(1)
  end
end
