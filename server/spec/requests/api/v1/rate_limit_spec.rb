require 'rails_helper'

# Rack::Attack is disabled in the test environment (see
# config/initializers/rack_attack.rb) so the throttles never make the rest
# of the suite flaky. This spec flips it on locally, against a real
# counting store (test's default :null_store never counts), and resets
# everything afterwards.
RSpec.describe "Device API rate limiting", type: :request do
  let!(:device) { create(:device) }
  let(:headers) { { "X-Api-Token" => device.raw_token } }

  around do |example|
    original_enabled = Rack::Attack.enabled
    original_store = Rack::Attack.cache.store
    Rack::Attack.enabled = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new

    example.run

    Rack::Attack.enabled = original_enabled
    Rack::Attack.cache.store = original_store
  end

  it "never throttles a burst well within the daemon's realistic sync traffic" do
    40.times { get "/api/v1/queue_version", headers: headers }

    expect(response).to have_http_status(:ok)
  end

  it "throttles a token once it blows well past the generous per-minute limit" do
    Rack::Attack::DEVICE_API_LIMIT.times do
      get "/api/v1/queue_version", headers: headers
    end
    expect(response).to have_http_status(:ok)

    get "/api/v1/queue_version", headers: headers
    expect(response).to have_http_status(:too_many_requests)
  end

  it "keys the throttle per device token, not globally" do
    other_device = create(:device)

    Rack::Attack::DEVICE_API_LIMIT.times do
      get "/api/v1/queue_version", headers: headers
    end

    get "/api/v1/queue_version", headers: { "X-Api-Token" => other_device.raw_token }
    expect(response).to have_http_status(:ok)
  end
end
