require "rails_helper"

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

  describe "reader_preferences" do
    it "returns defaults when nothing is stored" do
      expect(user.reader_preferences).to eq(User::DEFAULT_READER_PREFERENCES)
    end

    it "deep-merges stored values over defaults" do
      user.update!(reader_preferences: { "fontSize" => 120, "theme" => "dark" })
      prefs = user.reload.reader_preferences
      expect(prefs["fontSize"]).to eq(120)
      expect(prefs["theme"]).to eq("dark")
      expect(prefs["fontFamily"]).to eq("publisher")
      expect(prefs["hyphenate"]).to eq(true)
      expect(prefs["keepScreenOn"]).to eq(true)
    end

    it "whitelists keys, clamps numbers, and ignores junk without raising" do
      result = user.update_reader_preferences!(
        "fontSize" => 999,
        "lineHeight" => 0.5,
        "margin" => -10,
        "theme" => "neon",
        "flow" => "paginated",
        "fontFamily" => "literata",
        "justify" => true,
        "hyphenate" => "false",
        "keepScreenOn" => "0",
        "evil" => "drop me",
        "fontSize_hack" => 1
      )

      expect(result["fontSize"]).to eq(200)
      expect(result["lineHeight"]).to eq(1.2)
      expect(result["margin"]).to eq(0)
      expect(result["theme"]).to eq("light") # invalid theme ignored; default remains
      expect(result["flow"]).to eq("paginated")
      expect(result["fontFamily"]).to eq("literata")
      expect(result["justify"]).to eq(true)
      expect(result["hyphenate"]).to eq(false)
      expect(result["keepScreenOn"]).to eq(false)
      expect(result).not_to have_key("evil")
    end

    it "accepts all eight font family keys" do
      User::FONT_FAMILIES.each do |key|
        prefs = user.update_reader_preferences!("fontFamily" => key)
        expect(prefs["fontFamily"]).to eq(key)
      end
    end
  end

  describe "#preferred_kindle" do
    it "returns the preferred physical device" do
      kindle = create(:device, kind: "kindle")
      user.update!(preferred_device: kindle)
      expect(user.preferred_kindle).to eq(kindle)
    end

    it "returns nil when preferred is missing or not a kindle" do
      expect(user.preferred_kindle).to be_nil
      web = Device.web_reader!
      expect {
        user.update!(preferred_device: web)
      }.to raise_error(ActiveRecord::RecordInvalid)
      expect(user.reload.preferred_kindle).to be_nil
    end
  end
end
