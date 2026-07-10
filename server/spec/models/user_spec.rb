require 'rails_helper'

RSpec.describe User, type: :model do
  let!(:user) { create(:user) }

  it "normalizes the email address" do
    user.update!(email_address: "  Nik@Example.COM ")
    expect(user.email_address).to eq("nik@example.com")
  end

  it "authenticates by password" do
    expect(user.authenticate("password")).to eq(user)
    expect(user.authenticate("wrong")).to be_falsey
  end
end
