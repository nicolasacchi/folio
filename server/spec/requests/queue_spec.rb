require "rails_helper"

RSpec.describe "Queue", type: :request do
  let!(:user) { create(:user) }

  before do
    post session_path, params: { email_address: user.email_address, password: "password" }
  end

  it "hints at what an eviction reason means for a delivery pending removal" do
    device = create(:device)
    delivery = create(:delivery, :delivered, book: create(:book), device: device)
    delivery.request_eviction!("never opened")

    get queue_path

    expect(response.body).to include(
      %(title="Delivered more than 7 days ago and still never opened.">never opened)
    )
  end
end
