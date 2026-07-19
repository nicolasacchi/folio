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

    before_action :authenticate_opds_user!

    private

    attr_reader :current_opds_user

    # User.authenticate_by (has_secure_password, see app/models/user.rb) is
    # the same method the web login form uses (SessionsController#create)
    # and already runs a dummy bcrypt comparison when the email doesn't
    # match anything, so a bad email and a bad password fail in the same
    # amount of time — no separate constant-time handling needed here.
    def authenticate_opds_user!
      authenticate_or_request_with_http_basic(REALM) do |email, password|
        @current_opds_user = User.authenticate_by(email_address: email, password: password)
        @current_opds_user.present?
      end
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
