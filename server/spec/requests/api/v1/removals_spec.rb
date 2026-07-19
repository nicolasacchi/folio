require 'rails_helper'

RSpec.describe "API v1 removals", type: :request do
  let!(:device) { create(:device) }
  let(:headers) { { "X-Api-Token" => device.raw_token } }
  let!(:book) { create(:book) }
  let!(:delivery) do
    create(:delivery, :delivered, book: book, device: device).tap { |d| d.request_eviction!("finished") }
  end

  it "marks the delivery removed" do
    post "/api/v1/removals/#{delivery.id}/ack", headers: headers

    expect(response).to have_http_status(:ok)
    expect(delivery.reload).to be_removed
  end

  it "is idempotent" do
    2.times { post "/api/v1/removals/#{delivery.id}/ack", headers: headers }
    expect(response).to have_http_status(:ok)
  end

  it "rejects acks for another device's delivery" do
    other = create(:device)
    post "/api/v1/removals/#{delivery.id}/ack", headers: { "X-Api-Token" => other.raw_token }

    expect(response).to have_http_status(:not_found)
    expect(delivery.reload).not_to be_removed
  end
end
