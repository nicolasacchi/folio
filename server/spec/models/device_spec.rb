require 'rails_helper'

RSpec.describe Device, type: :model do
  let!(:device) { create(:device) }

  describe "token generation" do
    it "assigns a random raw token and stores only its SHA-256 digest" do
      fresh = Device.new(name: "fresh-device", kind: "kindle")
      fresh.valid?

      expect(fresh.raw_token).to match(/\A\h{40}\z/)
      expect(fresh.token_digest).to eq(Device.digest_token(fresh.raw_token))
      expect(fresh.token_digest).not_to eq(fresh.raw_token)
    end

    it "generates a different token per device" do
      other = build(:device, name: "other-device").tap { |d| d.valid? }
      expect(other.raw_token).not_to eq(device.raw_token)
    end

    it "does not persist the plaintext token anywhere on the record" do
      expect(device).not_to respond_to(:token)
    end
  end

  describe ".digest_token" do
    it "is a plain SHA-256 hexdigest, independent of any Device instance" do
      expect(Device.digest_token("abc")).to eq(Digest::SHA256.hexdigest("abc"))
    end
  end

  describe ".authenticate_by_token" do
    it "finds the device whose digest matches the given raw token" do
      expect(Device.authenticate_by_token(device.raw_token)).to eq(device)
    end

    it "returns nil for a wrong token" do
      expect(Device.authenticate_by_token("not-the-token")).to be_nil
    end

    it "returns nil for a blank token" do
      expect(Device.authenticate_by_token(nil)).to be_nil
      expect(Device.authenticate_by_token("")).to be_nil
    end

    it "does not authenticate by the stored digest itself" do
      expect(Device.authenticate_by_token(device.token_digest)).to be_nil
    end

    # Migration-parity guard: a device created through the normal
    # assign_token path (not the factory's forced deterministic token)
    # must still authenticate by the raw token it was handed at creation
    # — i.e. generation and lookup compute the exact same digest. This is
    # the same invariant the token_digest backfill migration depends on.
    it "authenticates a normally-created device by its generated raw token" do
      bare = Device.create!(name: "bare-device", kind: "kindle")
      expect(Device.authenticate_by_token(bare.raw_token)).to eq(bare)
    end
  end

  it "requires a unique name" do
    expect(build(:device, name: device.name)).not_to be_valid
  end

  describe "scopes" do
    let!(:web_device) { Device.web_reader! }

    it "splits physical hardware from the synthetic web device" do
      expect(Device.physical).to contain_exactly(device)
      expect(Device.web).to contain_exactly(web_device)
    end
  end

  describe ".web_reader!" do
    it "finds or creates a single synthetic web device" do
      first = Device.web_reader!
      expect(first.kind).to eq("web")
      expect(Device.web_reader!).to eq(first)
    end

    it "authenticates via the raw token generated for it, like a physical device" do
      web = Device.web_reader!
      expect(Device.authenticate_by_token(web.raw_token)).to eq(web)
    end
  end

  describe "main_user" do
    let!(:owner) { create(:user, email_address: "owner@example.com") }

    it "belongs to an optional main user on physical devices" do
      device.update!(main_user: owner)
      expect(device.reload.main_user).to eq(owner)
      expect(owner.owned_devices).to include(device)
    end

    it "rejects main_user on the synthetic web device" do
      web = Device.web_reader!
      web.main_user = owner
      expect(web).not_to be_valid
      expect(web.errors[:main_user]).to be_present
    end
  end
end
