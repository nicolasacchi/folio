require "rails_helper"

RSpec.describe "Deep health check", type: :request do
  describe "GET /healthz/deep" do
    it "reports a healthy DB with 200, unauthenticated" do
      get "/healthz/deep"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["db"]).to eq("ok")
      expect(response.parsed_body["queue"]).to be_in(%w[ok stale])
    end

    it "returns 503 with db: down when the write check fails" do
      allow(ActiveRecord::Base).to receive(:transaction).and_raise(ActiveRecord::StatementInvalid, "database is locked")

      get "/healthz/deep"

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body["db"]).to eq("down")
    end

    it "stays 200 with queue: stale when the queue is stale (non-fatal by default)" do
      allow_any_instance_of(HealthController).to receive(:queue_stale?).and_return(true)

      get "/healthz/deep"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["db"]).to eq("ok")
      expect(response.parsed_body["queue"]).to eq("stale")
    end

    it "reports queue: ok when a worker heartbeated recently" do
      allow_any_instance_of(HealthController).to receive(:queue_stale?).and_return(false)

      get "/healthz/deep"

      expect(response.parsed_body["queue"]).to eq("ok")
    end
  end
end
