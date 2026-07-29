require "rails_helper"

RSpec.describe "Reading page", type: :request do
  let!(:user_a) { create(:user, email_address: "a@example.com") }
  let!(:user_b) { create(:user, email_address: "b@example.com") }
  let!(:device) { create(:device, name: "paperwhite") }
  let!(:web_device) { Device.web_reader! }

  let!(:book_a) { create(:book, title: "Alice Book") }
  let!(:book_b) { create(:book, title: "Bob Book") }
  let!(:kindle_book) { create(:book, title: "Kindle Book") }

  def sign_in(user, password: "password")
    post session_path, params: { email_address: user.email_address, password: password }
  end

  before do
    create(:reader_position, book: book_a, user: user_a, percent: 30)
    create(:reader_position, book: book_b, user: user_b, percent: 97)
    create(:reading_state, book: kindle_book, device: device, progress_percent: 20, content_mtime: 1.day.ago)
    create(:reading_state, book: book_a, device: web_device, progress_percent: 30, content_mtime: 1.hour.ago)
  end

  it "scopes web reading to the signed-in user and excludes the synthetic web device from Kindles" do
    sign_in(user_a)
    get reading_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Alice Book")
    expect(response.body).not_to include("Bob Book")
    expect(response.body).to include("Kindle Book")
    expect(response.body).to include("paperwhite")
    expect(response.body).not_to include("Folio Web")
    expect(response.body).to include("1 book opened on web")
    expect(response.body).to include("0 books finished on web")
    expect(response.body).to include("1 book on the kindles")
  end

  it "never shows another user's positions" do
    sign_in(user_b)
    get reading_path

    expect(response.body).to include("Bob Book")
    expect(response.body).not_to include("Alice Book")
    expect(response.body).to include("1 book finished on web")
  end
end
