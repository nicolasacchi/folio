require 'rails_helper'

RSpec.describe "User management", type: :request do
  let!(:admin) { create(:user, email_address: "admin@example.com", admin: true) }

  def sign_in(user, password: "password")
    post session_path, params: { email_address: user.email_address, password: password }
  end

  describe "access" do
    it "hides the page from non-admins" do
      reader = create(:user, email_address: "reader@example.com")
      sign_in(reader)

      get users_path
      expect(response).to redirect_to(root_path)
    end

    it "shows the page to admins" do
      sign_in(admin)
      get users_path
      expect(response.body).to include("admin@example.com")
    end
  end

  describe "create" do
    before { sign_in(admin) }

    it "adds a user with a given password" do
      post users_path, params: { user: { email_address: "new@example.com", password: "s3cretpass" } }

      expect(User.find_by(email_address: "new@example.com")).to be_present
      expect(User.find_by(email_address: "new@example.com").admin).to be(false)
    end

    it "generates a password when blank and shows it once" do
      post users_path, params: { user: { email_address: "gen@example.com", password: "" } }
      follow_redirect!

      expect(response.body).to include("Password:")
      expect(User.find_by(email_address: "gen@example.com")).to be_present
    end

    it "can add another admin" do
      post users_path, params: { user: { email_address: "second@example.com", password: "s3cretpass", admin: "1" } }
      expect(User.find_by(email_address: "second@example.com")).to be_admin
    end
  end

  describe "update" do
    before { sign_in(admin) }

    it "resets a password" do
      reader = create(:user, email_address: "reader@example.com")
      patch user_path(reader), params: { user: { password: "newpassword" } }

      expect(reader.reload.authenticate("newpassword")).to be_truthy
    end

    it "never lets an admin demote themselves" do
      patch user_path(admin), params: { user: { admin: "0", password: "" } }
      expect(admin.reload).to be_admin
    end

    it "refuses to demote the last admin" do
      # The self-edit guard already strips :admin; simulate a second admin
      # demoting path where the target is the only admin.
      other_admin = create(:user, email_address: "other@example.com", admin: true)
      admin.update!(admin: false)
      sign_in(other_admin)

      patch user_path(other_admin), params: { user: { admin: "0", password: "" } }
      expect(other_admin.reload).to be_admin
    end
  end

  describe "destroy" do
    before { sign_in(admin) }

    it "removes a user and their sessions" do
      reader = create(:user, email_address: "reader@example.com")
      delete user_path(reader)

      expect(User.find_by(email_address: "reader@example.com")).to be_nil
    end

    it "refuses to delete yourself" do
      delete user_path(admin)
      expect(User.find_by(id: admin.id)).to be_present
    end
  end
end
