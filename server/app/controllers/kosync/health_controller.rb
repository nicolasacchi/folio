module Kosync
  class HealthController < Kosync::BaseController
    skip_before_action :authenticate_kosync_credential!

    # GET /kosync/healthcheck — unauthenticated liveness probe (the
    # reference server's docker image wires its HEALTHCHECK to this same
    # path); no equivalent value in checking a specific credential, so
    # unlike every other kosync route this one skips auth entirely.
    def show
      render json: { state: "OK" }
    end
  end
end
