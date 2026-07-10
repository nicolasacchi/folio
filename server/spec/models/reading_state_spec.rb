require 'rails_helper'

RSpec.describe ReadingState, type: :model do
  let!(:state) { create(:reading_state) }

  it "allows one state per book and device" do
    duplicate = build(:reading_state, book: state.book, device: state.device)
    expect(duplicate).not_to be_valid
  end

  it "orders latest_reading_state by content mtime" do
    newer_device = create(:device)
    newer = create(:reading_state, book: state.book, device: newer_device,
                                   content_mtime: state.content_mtime + 1.hour)

    expect(state.book.latest_reading_state).to eq(newer)
  end
end
