require "rails_helper"

RSpec.describe "Reader preferences", type: :request do
  let!(:user) { create(:user) }

  def sign_in(user, password: "password")
    post session_path, params: { email_address: user.email_address, password: password }
  end

  describe "PUT /reader/preferences" do
    it "requires authentication" do
      put reader_preferences_path, params: { preferences: { fontSize: 120 } }, as: :json
      expect(response).to redirect_to(new_session_path)
    end

    it "saves whitelisted prefs and clamps values" do
      sign_in(user)

      put reader_preferences_path, params: {
        preferences: {
          fontSize: 250,
          lineHeight: 3,
          margin: 100,
          theme: "sepia",
          flow: "scrolled",
          fontFamily: "bitter",
          justify: true,
          hyphenate: false,
          keepScreenOn: false,
          pageMode: "zoom",
          unknown: "nope"
        }
      }, as: :json

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["fontSize"]).to eq(200)
      expect(body["lineHeight"]).to eq(2.4)
      expect(body["margin"]).to eq(64)
      expect(body["theme"]).to eq("sepia")
      expect(body["flow"]).to eq("scrolled")
      expect(body["fontFamily"]).to eq("bitter")
      expect(body["justify"]).to eq(true)
      expect(body["hyphenate"]).to eq(false)
      expect(body["keepScreenOn"]).to eq(false)
      expect(body["pageMode"]).to eq("zoom")
      expect(body).not_to have_key("unknown")

      prefs = user.reload.reader_preferences
      expect(prefs["fontFamily"]).to eq("bitter")
      expect(prefs["fontSize"]).to eq(200)
      expect(prefs["pageMode"]).to eq("zoom")
    end

    it "defaults pageMode to fit and rejects values outside the allowlist" do
      expect(user.reader_preferences["pageMode"]).to eq("fit")

      sign_in(user)
      put reader_preferences_path, params: { preferences: { pageMode: "banana" } }, as: :json

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["pageMode"]).to eq("fit")
      expect(user.reload.reader_preferences["pageMode"]).to eq("fit")
    end

    it "exposes merged prefs on the reader page" do
      user.update_reader_preferences!("fontFamily" => "literata", "theme" => "dark")
      book = create(:book)
      create(:book_file, :epub_fixture, book: book)
      sign_in(user)

      get read_book_path(book)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-reader-server-preferences-value")
      expect(response.body).to include("literata")
      expect(response.body).to include("dark")
    end
  end
end
