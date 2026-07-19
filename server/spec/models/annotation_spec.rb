require 'rails_helper'

RSpec.describe Annotation, type: :model do
  it "accepts the known sources" do
    expect(build(:annotation, source: "clippings")).to be_valid
    expect(build(:annotation, source: "web", color: "yellow")).to be_valid
  end

  it "rejects an unknown source" do
    expect(build(:annotation, source: "printer")).not_to be_valid
  end
end
