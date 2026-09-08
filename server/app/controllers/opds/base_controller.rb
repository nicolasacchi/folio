# HTTP Basic auth for the whole OPDS surface, gating both feeds and
# acquisition/cover/thumbnail downloads (OPDS clients — KOReader, Thorium,
# Marvin, Panels — send the same Basic credentials on every request, not
# just the initial feed fetch, so this must sit in front of everything
# under /opds, not just Opds::CatalogController).
#
# Deliberately ActionController::Base, not ApplicationController: the web
# session cookie (Authentication concern) and the device API's Bearer/
# X-Api-Token (Api::V1::BaseController) are both separate identities from
# a household user's own login, and CSRF protection is meaningless for a
# GET-only, non-browser API.
module Opds
  class BaseController < ActionController::Base
    REALM = "Folio OPDS"
    PER_PAGE = 48 # matches BooksController::PER_PAGE (the web index)

    # Failed-auth throttle (the strict half of the OPDS rate limiting — see
    # config/initializers/rack_attack.rb for why it lives here and not in
    # Rack::Attack): this many wrong-password attempts per ip+username
    # within the window turns further attempts into 429s. Counting happens
    # only on actual failures, so a legit client reusing valid credentials
    # on every request never accrues anything.
    AUTH_FAILURE_LIMIT = 30
    AUTH_FAILURE_PERIOD = 5.minutes

    before_action :authenticate_opds_user!

    private

    attr_reader :current_opds_user

    # User.authenticate_by (has_secure_password, see app/models/user.rb) is
    # the same method the web login form uses (SessionsController#create)
    # and already runs a dummy bcrypt comparison when the email doesn't
    # match anything, so a bad email and a bad password fail in the same
    # amount of time — no separate constant-time handling needed here.
    def authenticate_opds_user!
      if auth_failure_throttled?
        response.set_header("Retry-After", AUTH_FAILURE_PERIOD.to_i.to_s)
        render plain: "Too many failed sign-in attempts — try again later.", status: :too_many_requests
        return
      end

      authenticate_or_request_with_http_basic(REALM) do |email, password|
        @current_opds_user = User.authenticate_by(email_address: email, password: password)
        record_auth_failure(email) unless @current_opds_user
        @current_opds_user.present?
      end
    end

    def auth_failure_throttled?
      username = ActionController::HttpAuthentication::Basic.user_name_and_password(request)&.first
      auth_failure_count(auth_failure_key(username)) >= AUTH_FAILURE_LIMIT
    end

    def record_auth_failure(email)
      key = auth_failure_key(email)
      Rails.cache.write(key, auth_failure_count(key) + 1, expires_in: AUTH_FAILURE_PERIOD)
    rescue StandardError => e
      # A broken cache backend must never lock legit users out of OPDS.
      Rails.logger.error("[opds] auth-failure throttle write failed: #{e.class}")
    end

    def auth_failure_count(key)
      Rails.cache.read(key).to_i
    rescue StandardError => e
      Rails.logger.error("[opds] auth-failure throttle read failed: #{e.class}")
      0
    end

    # Keyed by the Basic-auth username (strip+downcase — User.email_address
    # normalizes the same way, see app/models/user.rb) plus IP, so
    # one targeted account locks out only that ip+username pair and other
    # users behind the same NAT keep working.
    def auth_failure_key(username)
      "opds/auth_failures/#{request.remote_ip}/#{username.to_s.strip.downcase}"
    end

    # Books with at least one currently-deliverable file. BookFile#available
    # tracks exactly this (Library::Scan flips it false the moment a
    # referenced-in-place file goes missing from disk, true again once it
    # reappears) — the same signal the guide recommends and the only one
    # that already accounts for scanned-but-currently-absent files.
    def available_books
      Book.joins(:book_files).merge(BookFile.available).distinct
    end
  end
end
