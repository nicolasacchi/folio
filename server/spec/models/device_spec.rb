require 'rails_helper'

RSpec.describe Device, type: :model do
  let!(:device) { create(:device) }

  it "generates a unique token on creation" do
    expect(device.token).to match(/\A\h{40}\z/)
    expect(create(:device).token).not_to eq(device.token)
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
  end
end
