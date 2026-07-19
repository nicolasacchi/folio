require "rails_helper"

RSpec.describe "Annotations index", type: :request do
  let!(:user) { create(:user) }

  before do
    post session_path, params: { email_address: user.email_address, password: "password" }
  end

  it "explains the Kindle-location abbreviation on a location label" do
    book = create(:book)
    device = create(:device)
    create(:annotation, book: book, device: device, location_start: 340, location_end: 355)

    get annotations_path

    expect(response.body).to include(%(<abbr title="Kindle location, not a page number">loc.</abbr>))
  end

  it "does not render the abbreviation when there is no location" do
    book = create(:book)
    device = create(:device)
    create(:annotation, book: book, device: device, location_start: nil, page: nil)

    get annotations_path

    expect(response.body).not_to include("<abbr")
  end
end
