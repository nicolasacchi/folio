require "rails_helper"

# Covers both halves of OPDS rate limiting (see
# config/initializers/rack_attack.rb for why they're split):
#  - the broad per-IP Rack::Attack ceiling over all of /opds;
#  - the stricter failed-Basic-auth throttle in Opds::BaseController,
#    which counts actual 401s per ip+username (Rack::Attack runs before
#    the app and can't see the response status).
# Rack::Attack is disabled in the test environment, so like
# spec/requests/api/v1/rate_limit_spec.rb this flips it on locally with a
# real counting store; the controller half reads Rails.cache, which is
# :null_store in test and likewise needs a counting stand-in.
RSpec.describe "OPDS rate limiting", type: :request do
  let!(:user) { create(:user, email_address: "reader@example.com", password: "password") }

  def basic_auth(email, password)
    { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(email, password) }
  end

  around do |example|
    original_enabled = Rack::Attack.enabled
    original_attack_store = Rack::Attack.cache.store
    original_cache = Rails.cache
    Rack::Attack.enabled = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    example.run

    Rack::Attack.enabled = original_enabled
    Rack::Attack.cache.store = original_attack_store
    Rails.cache = original_cache
  end

  it "never throttles a browsing burst well within a real client's traffic" do
    40.times { get "/opds", headers: basic_auth("reader@example.com", "password") }

    expect(response).to have_http_status(:ok)
  end

  it "throttles an IP that blows well past the per-minute ceiling" do
    # Unauthenticated requests (no bcrypt) keep this fast; the broad IP
    # throttle is credential-agnostic.
    Rack::Attack::OPDS_LIMIT.times { get "/opds" }
    expect(response).to have_http_status(:unauthorized)

    get "/opds"
    expect(response).to have_http_status(:too_many_requests)
  end

  it "429s repeated wrong-password attempts for the same ip+username" do
    stub_const("Opds::BaseController::AUTH_FAILURE_LIMIT", 5)

    5.times do
      get "/opds", headers: basic_auth("reader@example.com", "wrong")
      expect(response).to have_http_status(:unauthorized)
    end

    get "/opds", headers: basic_auth("reader@example.com", "wrong")
    expect(response).to have_http_status(:too_many_requests)
    expect(response.headers["Retry-After"]).to be_present
  end

  it "does not count successful auth against the failure throttle" do
    stub_const("Opds::BaseController::AUTH_FAILURE_LIMIT", 5)

    10.times { get "/opds", headers: basic_auth("reader@example.com", "password") }

    expect(response).to have_http_status(:ok)
  end

  it "keys the failure throttle per username, not per IP alone" do
    stub_const("Opds::BaseController::AUTH_FAILURE_LIMIT", 5)

    5.times { get "/opds", headers: basic_auth("reader@example.com", "wrong") }

    get "/opds", headers: basic_auth("other@example.com", "password")
    expect(response).not_to have_http_status(:too_many_requests)
  end

  it "throttles a padded username as the same key as the stripped one" do
    stub_const("Opds::BaseController::AUTH_FAILURE_LIMIT", 5)

    5.times { get "/opds", headers: basic_auth("reader@example.com", "wrong") }

    get "/opds", headers: basic_auth(" reader@example.com ", "wrong")
    expect(response).to have_http_status(:too_many_requests)
  end
end
