module Kosync
  class UsersController < Kosync::BaseController
    # No credential can exist to authenticate against yet.
    skip_before_action :authenticate_kosync_credential!, only: :create

    # POST /kosync/users/create — KOReader's "Register" call. `password` in
    # the request body is already the MD5-hex of the plaintext (KOReader
    # hashes client-side before ever sending it — see KosyncCredential) —
    # Folio bcrypts that hex, it never sees or stores the real password.
    def create
      unless KosyncCredential.open_registration?
        return render_kosync_error(:payment_required, 2005, "User registration is disabled.")
      end

      username = params[:username].to_s
      key = params[:password].to_s

      return render_kosync_error(:forbidden, 2003, "Invalid request") if username.blank? || key.blank?

      credential = KosyncCredential.new(username: username, key: key)
      if credential.save
        render json: { username: credential.username }, status: :created
      elsif credential.errors.of_kind?(:username, :taken)
        render_kosync_error(:payment_required, 2002, "Username is already registered.")
      else
        render_kosync_error(:forbidden, 2003, "Invalid request")
      end
    end

    # GET /kosync/users/auth — KOReader's "Login" call. Reaching this
    # action at all means the before_action already authenticated the
    # credential; there is nothing left to check.
    def auth
      render json: { authorized: "OK" }
    end
  end
end
