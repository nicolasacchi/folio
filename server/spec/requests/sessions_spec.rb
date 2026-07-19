require 'rails_helper'

RSpec.describe "Sessions", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:user) { create(:user, email_address: "reader@example.com") }

  def sign_in
    post session_path, params: { email_address: user.email_address, password: "password" }
  end

  it "stays authenticated within the session's max age" do
    sign_in
    travel_to(Authentication::SESSION_MAX_AGE.from_now - 1.day) do
      get root_path
      expect(response).not_to redirect_to(new_session_path)
    end
  end

  it "rejects and destroys a session older than the absolute max age" do
    sign_in
    expect(Session.count).to eq(1)

    travel_to(Authentication::SESSION_MAX_AGE.from_now + 1.day) do
      get root_path
      expect(response).to redirect_to(new_session_path)
    end

    expect(Session.count).to eq(0)
  end

  it "behaves like an unauthenticated request once expired, not an error" do
    sign_in

    travel_to(Authentication::SESSION_MAX_AGE.from_now + 1.day) do
      get root_path
      follow_redirect!
      expect(response).to have_http_status(:ok)
    end
  end
end
