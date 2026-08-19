require 'rails_helper'

RSpec.describe ReaderPosition, type: :model do
  it "enforces one position per book per user per variant" do
    position = create(:reader_position)
    dup = build(:reader_position, book: position.book, user: position.user)

    expect(dup).not_to be_valid
    expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "allows the same user a position on a different book" do
    position = create(:reader_position)
    expect(build(:reader_position, user: position.user)).to be_valid
  end

  it "allows the same book/user a separate position for the 'text' variant" do
    position = create(:reader_position, variant: "")
    expect(build(:reader_position, book: position.book, user: position.user, variant: "text")).to be_valid
  end

  it "rejects an unknown variant" do
    expect(build(:reader_position, variant: "raw")).not_to be_valid
  end
end
