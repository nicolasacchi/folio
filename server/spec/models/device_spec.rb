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
end
