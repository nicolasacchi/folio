# Admin-only account management. Admins invite readers (optionally
# fellow admins), reset passwords, and revoke access. Guards keep the
# instance administrable: you can't delete yourself or demote/delete the
# last admin.
class UsersController < ApplicationController
  before_action :require_admin!
  before_action :set_user, only: [ :update, :destroy ]

  def index
    @users = User.order(:email_address)
    @user = User.new
  end

  def create
    generated = params.dig(:user, :password).blank?
    attrs = user_params
    attrs[:password] = SecureRandom.base58(12) if generated

    user = User.new(attrs)
    if user.save
      # A generated password is rendered once, straight into this response
      # (@generated_password on the index view), never through the session
      # flash — flash round-trips the secret through the cookie/cache store
      # and shows it again on every later render until it's consumed.
      if generated
        @generated_password = attrs[:password]
        @created_email = user.email_address
        @users = User.order(:email_address)
        @user = User.new
        flash.now[:notice] = "#{user.email_address} added."
        render :index
      else
        redirect_to users_path, notice: "#{user.email_address} added."
      end
    else
      redirect_to users_path, alert: user.errors.full_messages.to_sentence
    end
  end

  def update
    attrs = user_params
    attrs.delete(:password) if attrs[:password].blank?
    changing_password = attrs.key?(:password)
    if demoting_last_admin?(attrs)
      return redirect_to users_path, alert: "At least one admin must remain."
    end

    if @user.update(attrs)
      # An admin-issued password change must revoke the target's existing
      # sessions (self-service reset already does this in
      # PasswordsController) — otherwise a stolen session outlives the
      # credential change meant to kill it. Scoped to password changes only
      # so a plain email/admin-bit edit doesn't log the user out.
      @user.sessions.destroy_all if changing_password
      redirect_to users_path, notice: "#{@user.email_address} updated."
    else
      redirect_to users_path, alert: @user.errors.full_messages.to_sentence
    end
  end

  def destroy
    return redirect_to users_path, alert: "You cannot delete your own account." if @user == Current.user
    if @user.admin? && User.where(admin: true).count == 1
      return redirect_to users_path, alert: "At least one admin must remain."
    end

    @user.destroy!
    redirect_to users_path, notice: "#{@user.email_address} removed.", status: :see_other
  end

  private

  def require_admin!
    redirect_to root_path, alert: "Admins only." unless Current.user&.admin?
  end

  def set_user
    @user = User.find(params[:id])
  end

  def user_params
    permitted = params.expect(user: [ :email_address, :password, :admin ])
    # Nobody edits their own admin bit (no accidental lockout).
    permitted.delete(:admin) if @user == Current.user
    permitted
  end

  def demoting_last_admin?(attrs)
    @user.admin? && attrs.key?(:admin) &&
      ActiveModel::Type::Boolean.new.cast(attrs[:admin]) == false &&
      User.where(admin: true).count == 1
  end
end
