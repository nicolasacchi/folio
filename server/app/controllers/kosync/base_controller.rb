# Base for the kosync ("KOReader Progress sync") API — the small JSON
# HTTP surface a KOReader client hits once its user points "Custom sync
# server" at this Folio instance (see config/routes.rb's :kosync
# namespace for the exact paths and README for client setup). Deliberately
# its own ActionController::API tree: auth here is x-auth-user/x-auth-key
# against a KosyncCredential (see that model), never the device API's
# X-Api-Token (Api::V1::BaseController) or the web session/CSRF
# (ApplicationController) — and CSRF protection is meaningless for a
# non-browser JSON client anyway.
module Kosync
  class BaseController < ActionController::API
    before_action :authenticate_kosync_credential!

    attr_reader :current_kosync_credential

    private

    def authenticate_kosync_credential!
      @current_kosync_credential = KosyncCredential.authenticate_by(
        username: request.headers["X-Auth-User"],
        key: request.headers["X-Auth-Key"]
      )
      return if @current_kosync_credential

      render_kosync_error(:unauthorized, 2001, "Unauthorized")
    end

    # Mirrors the reference server's `{ code, message }` error body (see
    # koreader-sync-server's config/errors.lua) so a KOReader client's
    # error toast reads the same against Folio as against the official
    # sync.koreader.rocks. The client itself only branches on HTTP status,
    # never `code` — but matching it costs nothing and helps anyone
    # debugging with curl against the numeric codes in the protocol docs.
    def render_kosync_error(status, code, message)
      render json: { code: code, message: message }, status: status
    end
  end
end
